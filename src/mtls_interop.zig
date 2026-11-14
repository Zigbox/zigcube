//! `zig build mtls-interop`: the mTLS client against stock servers (docs/briefs/mtls-client.md,
//! "Interop acceptance", slice 7). **An interop check, not a demo.** Shell code: it starts
//! processes, opens sockets and reads the real clock.
//!
//! It issues a CA, a second CA, server certificates and workload certificates with the code under
//! test (`x509.zig`), starts `openssl s_server` and a JDK 21 `SSLServerSocket`
//! (`ops/mtls-interop/InteropServer.java`), connects with `tls_conn.zig` and asserts each outcome
//! by diagnostic code and message, not by exit status:
//!
//!   - accepted: bytes flow both ways, the server read the SPIFFE id and the private extension
//!     exactly (decoded by the Java decoder, which is independent of ours), and our `close_notify`
//!     ended the server's read cleanly;
//!   - refused by the server (another CA, expired, another job, no certificate): the alert is
//!     reported as ZC-E0814, named;
//!   - refused by the client (a server chain from another CA, an expired or misnamed server
//!     certificate, a server that does not ask for a certificate, a TLS 1.2 server, truncation);
//!   - server-sent events delivered as they arrive, and a stream across a KeyUpdate;
//!   - the workload-certificate row (B4 slice 4): the real relay (`relay.zig`), secured with the
//!     run's key, its job certificate (`spiffe://<cluster>/job/<name>`, issued by
//!     `peer_ca.Ca.issue_job_certificate`) written as `relay.crt` the way the agent writes it.
//!     The harness connects to the relay's loopback port as the job would. Accepted: a line
//!     crosses both ways, the server read the job's SPIFFE id and extension exactly, and the job's
//!     end reaches the server as `close_notify`. The JDK server pins the job's id (allow-list),
//!     and refuses another job's certificate; `openssl s_server` has no SPIFFE allow-list, so
//!     there the case asserts that it sees the other job's id. An expired certificate and one
//!     from another CA are refused by both: the relay's `relay.log` holds one ZC-E0814 line and
//!     the job's connection is closed. Without `relay.crt` the relay never dials: ZC-E0705, the
//!     job's connection closed, and the server's output unchanged (it saw no connection).
//!
//! The JDK and OpenSSL are test tools only: nothing here ships
//! (docs/decisions/2026-11-05-interop-tools-are-test-only.md). It prints to stdout only (the
//! build runner counts stderr as a failure) and kills every server it started.
//! Usage: `mtls_interop <InteropServer.java>`. `ZCUBE_JAVA_HOME` names the JDK, else `java` is
//! taken from PATH.

const std = @import("std");
const assert = std.debug.assert;
const agent_records = @import("agent_records.zig");
const diag_mod = @import("diag.zig");
const peer_ca = @import("peer_ca.zig");
const peer_stream = @import("peer_stream.zig");
const relay_module = @import("relay.zig");
const relay_tls = @import("relay_tls.zig");
const tls_client = @import("tls_client.zig");
const tls_conn = @import("tls_conn.zig");
const x509 = @import("x509.zig");
const x509_identity = @import("x509_identity.zig");

const Allocator = std.mem.Allocator;
const Code = @import("diag/codes.zig").Code;
const ManualClock = @import("clock.zig").ManualClock;
const Conn = tls_conn.Conn;
const Diag = diag_mod.Diag;
const Ed25519 = std.crypto.sign.Ed25519;

const Failed = error{CaseFailed};

const hour_ms: u64 = 3_600_000;
const server_name = "broker.botpike.com";
const cluster = "prod.example";
const job = "broker-1";
const spiffe_id = "spiffe://prod.example/service/broker-1";
/// The relayed run (B4): the job whose certificate the relay presents, and another job.
const relay_job = "nightly-7";
const relay_job_id = "spiffe://prod.example/job/nightly-7";
const other_job = "nightly-8";
const other_job_id = "spiffe://prod.example/job/nightly-8";
const java_major = "21";
const step_ms: u64 = 5000;
const events_count = 20;
/// The longest a helper tool (`javac`, `java --decode`, `openssl x509`) may go without output.
const tool_timeout: std.Io.Timeout = .{ .duration = .{
    .raw = .fromMilliseconds(120_000),
    .clock = .awake,
} };
const bulk_bytes: u32 = 3 * 1024 * 1024;

const labels = [_]x509_identity.Label{
    .{ .key = "app", .value = "broker" },
    .{ .key = "env", .value = "prod" },
};
const identity: x509_identity.Identity = .{
    .image_digest = @splat(0x5A),
    .placement_epoch = 42,
    .labels = &labels,
};

// ---- Certificates ----------------------------------------------------------------------------

const ServerCert = enum { good, other_ca, expired, wrong_name };
const ClientCert = enum { good, other_ca, expired, other_job, none };
/// The relay's `relay.crt`: the run's job certificate, or one of the four bad cases.
const JobCert = enum { good, other_job, expired, other_ca, none };

/// Every key and certificate the cases need, issued by the code under test.
const Pki = struct {
    ca: Ed25519.KeyPair,
    other_ca: Ed25519.KeyPair,
    server_key: Ed25519.KeyPair,
    client_key: Ed25519.KeyPair,
    clients: [4]x509.Der,
    /// The run's key, which the relay holds, and its job certificates (`JobCert` order).
    relay_key: Ed25519.KeyPair,
    jobs: [4]x509.Der,
    now: u64,

    fn init(pki: *Pki, now: u64) !void {
        pki.now = now;
        pki.ca = try Ed25519.KeyPair.generateDeterministic(@splat(0xCA));
        pki.other_ca = try Ed25519.KeyPair.generateDeterministic(@splat(0xCB));
        pki.server_key = try Ed25519.KeyPair.generateDeterministic(@splat(5));
        pki.client_key = try Ed25519.KeyPair.generateDeterministic(@splat(9));
        const valid = pki.window(false);
        const stale = pki.window(true);
        try pki.workload(&pki.clients[0], pki.ca, job, valid);
        try pki.workload(&pki.clients[1], pki.other_ca, job, valid);
        try pki.workload(&pki.clients[2], pki.ca, job, stale);
        try pki.workload(&pki.clients[3], pki.ca, "intruder-9", valid);
        pki.relay_key = try Ed25519.KeyPair.generateDeterministic(@splat(0x41));
        try pki.issue_job(&pki.jobs[0], pki.ca, relay_job, valid);
        try pki.issue_job(&pki.jobs[1], pki.ca, other_job, valid);
        try pki.issue_job(&pki.jobs[2], pki.ca, relay_job, stale);
        try pki.issue_job(&pki.jobs[3], pki.other_ca, relay_job, valid);
    }

    /// A relayed run's certificate for the relay's key, through the server's own issuance
    /// (`peer_ca.Ca.issue_job_certificate`, which `POST .../runs/{name}/certificate` calls).
    fn issue_job(
        pki: *const Pki,
        out: *x509.Der,
        signer: Ed25519.KeyPair,
        name: []const u8,
        lifetime: x509.Lifetime,
    ) !void {
        var clock: ManualClock = .{ .ms = pki.now };
        const ca: peer_ca.Ca = .{ .key = signer, .revoked = .{}, .wall = clock.clock() };
        try ca.issue_job_certificate(out, &.{
            .cluster = cluster,
            .name = name,
            .subject_key = pki.relay_key.public_key.toBytes(),
            .identity = identity,
            .lifetime = lifetime,
        });
    }

    fn job_cert(pki: *const Pki, which: JobCert) ?*const x509.Der {
        return switch (which) {
            .good => &pki.jobs[0],
            .other_job => &pki.jobs[1],
            .expired => &pki.jobs[2],
            .other_ca => &pki.jobs[3],
            .none => null,
        };
    }

    fn window(pki: *const Pki, expired: bool) x509.Lifetime {
        if (expired) return .{
            .not_before_ms = pki.now - 3 * hour_ms,
            .not_after_ms = pki.now - hour_ms,
        };
        return .{ .not_before_ms = pki.now - hour_ms, .not_after_ms = pki.now + hour_ms };
    }

    fn workload(
        pki: *const Pki,
        out: *x509.Der,
        signer: Ed25519.KeyPair,
        service: []const u8,
        lifetime: x509.Lifetime,
    ) !void {
        const request: x509.WorkloadRequest = .{
            .cluster = cluster,
            .name = service,
            .subject_key = pki.client_key.public_key.toBytes(),
            .identity = identity,
            .lifetime = lifetime,
        };
        try x509.issue_workload(out, signer, &request);
    }

    fn server(pki: *const Pki, out: *x509.Der, which: ServerCert) !void {
        const request: x509.ServerRequest = .{
            .dns_name = if (which == .wrong_name) "other.botpike.com" else server_name,
            .subject_key = pki.server_key.public_key.toBytes(),
            .lifetime = pki.window(which == .expired),
        };
        try x509.issue_server(out, if (which == .other_ca) pki.other_ca else pki.ca, &request);
    }

    fn client(pki: *const Pki, which: ClientCert) ?*const x509.Der {
        return switch (which) {
            .good => &pki.clients[0],
            .other_ca => &pki.clients[1],
            .expired => &pki.clients[2],
            .other_job => &pki.clients[3],
            .none => null,
        };
    }
};

/// PEM text for `bytes` under `label`.
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
    } ++
        [_]u8{ 0x04, 0x22, 0x04, 0x20 };
    return pem(arena, "PRIVATE KEY", &(prefix ++ seed));
}

// ---- Stock servers ---------------------------------------------------------------------------

const ServerKind = enum { openssl, java };
const Mode = enum { echo, sse, bulk };

const ServerSpec = struct {
    kind: ServerKind,
    cert: ServerCert = .good,
    /// The server asks for a client certificate and verifies it.
    ask: bool = true,
    /// Java only: the SPIFFE ids the server lets in (all of the CA's when null).
    allow: ?[]const u8 = null,
    mode: Mode = .echo,
    /// OpenSSL only: a TLS 1.2 server.
    tls12: bool = false,
    /// OpenSSL only: print the handshake messages, to see a KeyUpdate go by.
    messages: bool = false,
    /// Java only: a KeyUpdate after this many bytes, and the handshake debug that shows it.
    key_limit: bool = false,
};

const Server = struct {
    child: std.process.Child,
    log: []const u8,
    port: u16,
    kind: ServerKind,

    fn stop(server: *Server, io: std.Io) void {
        server.child.kill(io);
    }
};

const Harness = struct {
    io: std.Io,
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    /// Reset after every case.
    scratch: std.heap.ArenaAllocator,
    environ: *const std.process.Environ.Map,
    work: []const u8,
    java: []const u8,
    classes: []const u8,
    pki: *Pki,
    conn: *Conn,
    diag: *Diag,
    cases: u32 = 0,
    failures: u32 = 0,
    /// Why the running case failed, for the line it prints.
    why: [320]u8 = undefined,
    why_len: u32 = 0,

    fn say(h: *Harness, comptime format: []const u8, args: anytype) void {
        var buffer: [640]u8 = undefined;
        const line = std.fmt.bufPrint(&buffer, "mtls-interop: " ++ format ++ "\n", args) catch
            return;
        std.Io.File.stdout().writeStreamingAll(h.io, line) catch {}; // Nowhere else to say it.
    }

    fn check(h: *Harness, ok: bool, comptime what: []const u8, args: anytype) Failed!void {
        if (ok) return;
        const text = std.fmt.bufPrint(&h.why, what, args) catch h.why[0..0];
        h.why_len = @intCast(text.len);
        return error.CaseFailed;
    }

    fn path(h: *Harness, name: []const u8) []const u8 {
        return std.fmt.allocPrint(h.arena.allocator(), "{s}/{s}", .{ h.work, name }) catch
            @panic("out of memory");
    }

    fn write_file(h: *Harness, name: []const u8, data: []const u8) !void {
        try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = h.path(name), .data = data });
    }

    fn sleep_ms(h: *Harness, ms: i64) void {
        h.io.sleep(.fromMilliseconds(ms), .awake) catch {}; // Cancelled: the run is ending.
    }

    fn log_text(h: *Harness, server: *const Server) []const u8 {
        const scratch = h.scratch.allocator();
        const limit: std.Io.Limit = .limited(16 << 20);
        return std.Io.Dir.cwd().readFileAlloc(h.io, server.log, scratch, limit) catch "";
    }

    /// Waits until the server's output holds `text`.
    fn wait_log(h: *Harness, server: *const Server, text: []const u8, ms: u64) bool {
        const end = peer_stream.boot_ms(h.io) + ms;
        while (peer_stream.boot_ms(h.io) < end) {
            if (std.mem.find(u8, h.log_text(server), text) != null) return true;
            h.sleep_ms(20);
        }
        return std.mem.find(u8, h.log_text(server), text) != null;
    }

    /// A line of the server's output that starts with `prefix`.
    fn log_line(h: *Harness, server: *const Server, prefix: []const u8) ?[]const u8 {
        var lines = std.mem.splitScalar(u8, h.log_text(server), '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, prefix)) return line;
        }
        return null;
    }

    fn send(h: *Harness, server: *Server, text: []const u8) !void {
        const stdin = server.child.stdin orelse return error.NoStdin;
        // A pipe that polls writable has room for PIPE_BUF bytes, and `text` is shorter: the
        // write cannot block, and a server that stopped reading fails here, not in CI's timeout.
        assert(text.len <= 512);
        var fds = [1]std.posix.pollfd{.{
            .fd = stdin.handle,
            .events = std.posix.POLL.OUT,
            .revents = 0,
        }};
        const ready = try std.posix.poll(&fds, @intCast(step_ms));
        if (ready == 0) return error.ServerNotReading;
        try stdin.writeStreamingAll(h.io, text);
    }
};

fn free_port(io: std.Io) !u16 {
    const any = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try any.listen(io, .{});
    defer listener.deinit(io);
    return listener.socket.address.getPort();
}

fn cert_file(which: ServerCert) []const u8 {
    return switch (which) {
        .good => "server-good.pem",
        .other_ca => "server-other-ca.pem",
        .expired => "server-expired.pem",
        .wrong_name => "server-wrong-name.pem",
    };
}

fn spawn(h: *Harness, argv: []const []const u8, log: []const u8, pipe: bool) !std.process.Child {
    const file = try std.Io.Dir.cwd().createFile(h.io, log, .{});
    defer file.close(h.io);
    return std.process.spawn(h.io, .{
        .argv = argv,
        .stdin = if (pipe) .pipe else .ignore,
        .stdout = .{ .file = file },
        .stderr = .{ .file = file },
    });
}

fn start_openssl(h: *Harness, spec: ServerSpec) !Server {
    const scratch = h.scratch.allocator();
    const port = try free_port(h.io);
    const accept = try std.fmt.allocPrint(scratch, "127.0.0.1:{d}", .{port});
    var argv: std.ArrayList([]const u8) = .empty;
    // s_server ignores end of stdin, so the kernel ends it with the harness: SIGKILL on the
    // death of its parent, whatever the cause (a signal, a panic).
    try argv.appendSlice(scratch, &.{ "setpriv", "--pdeathsig", "KILL" });
    try argv.appendSlice(scratch, &.{ "openssl", "s_server", "-accept", accept });
    try argv.append(scratch, if (spec.tls12) "-tls1_2" else "-tls1_3");
    try argv.appendSlice(scratch, &.{
        "-cert",         h.path(cert_file(spec.cert)),
        "-key",          h.path("server.key"),
        "-ciphersuites", "TLS_AES_128_GCM_SHA256",
        "-groups",       "X25519",
        "-CAfile",       h.path("ca.pem"),
    });
    if (spec.ask) try argv.appendSlice(scratch, &.{ "-Verify", "1", "-verify_return_error" });
    if (spec.messages) try argv.append(scratch, "-msg");
    const log = try std.fmt.allocPrint(scratch, "{s}/openssl-{d}.log", .{ h.work, port });
    var server: Server = .{
        .child = try spawn(h, argv.items, log, true),
        .log = log,
        .port = port,
        .kind = .openssl,
    };
    errdefer server.stop(h.io);
    if (!h.wait_log(&server, "ACCEPT", 10_000)) return error.ServerNotUp;
    return server;
}

fn start_java(h: *Harness, spec: ServerSpec) !Server {
    const scratch = h.scratch.allocator();
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(scratch, h.java);
    // A client that drops TCP without close_notify must fail `close_clean`, not read as clean.
    try argv.append(scratch, "-Dcom.sun.net.ssl.requireCloseNotify=true");
    if (spec.key_limit) try argv.appendSlice(scratch, &.{
        try std.fmt.allocPrint(scratch, "-Djava.security.properties={s}", .{h.path("jdk.props")}),
        "-Djavax.net.debug=ssl:handshake",
    });
    try argv.appendSlice(scratch, &.{
        "-cp",                        h.classes,
        "InteropServer",              h.path("ca.pem"),
        h.path(cert_file(spec.cert)), h.path("server.key"),
        "--mode",                     @tagName(spec.mode),
    });
    if (!spec.ask) try argv.append(scratch, "--no-client-auth");
    if (spec.allow) |uri| try argv.appendSlice(scratch, &.{ "--allow", uri });
    const log = try std.fmt.allocPrint(scratch, "{s}/java-{d}.log", .{ h.work, h.cases });
    var server: Server = .{
        // The pipe is the JVM's lifetime: it exits when the harness dies and the pipe closes.
        .child = try spawn(h, argv.items, log, true),
        .log = log,
        .port = 0,
        .kind = .java,
    };
    errdefer server.stop(h.io);
    if (!h.wait_log(&server, "LISTENING ", 20_000)) return error.ServerNotUp;
    const line = h.log_line(&server, "LISTENING ") orelse return error.ServerNotUp;
    server.port = try std.fmt.parseInt(u16, std.mem.trim(u8, line["LISTENING ".len..], " \r"), 10);
    return server;
}

fn start_server(h: *Harness, spec: ServerSpec) !Server {
    return switch (spec.kind) {
        .openssl => start_openssl(h, spec),
        .java => start_java(h, spec),
    };
}

// ---- The client ------------------------------------------------------------------------------

const ClientSpec = struct {
    cert: ClientCert = .good,
    /// The name the client expects the server to have.
    name: []const u8 = server_name,
    /// Fail if the server does not ask for a certificate (the default for a workload).
    require: bool = true,
};

/// One connection of the code under test.
const Session = struct {
    h: *Harness,
    fd: std.posix.fd_t,
    identity: tls_client.Identity,
    chain: [1][]const u8,

    fn close_fd(session: *Session) void {
        _ = std.os.linux.close(session.fd);
    }
};

fn describe(h: *Harness, buffer: []u8) []const u8 {
    const diag = h.diag;
    if (diag.code == null) return "(no diagnostic)";
    const cause = diag.last_cause() orelse "";
    return std.fmt.bufPrint(buffer, "ZC-{s}: {s}", .{ @tagName(diag.code.?), cause }) catch "?";
}

/// Opens the connection. False when the client refused it: the diagnostic is in `h.diag`.
fn open_session(h: *Harness, session: *Session, port: u16, spec: ClientSpec) !bool {
    h.diag.reset();
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    session.h = h;
    session.fd = try peer_stream.connect(h.io, address, peer_stream.boot_ms(h.io) + step_ms);
    var auth: tls_client.ClientAuth = .none;
    if (h.pki.client(spec.cert)) |certificate| {
        session.chain = .{certificate.slice()};
        session.identity = .{
            .certificates = &session.chain,
            .signer = tls_client.key_pair_signer(&h.pki.client_key),
        };
        auth = if (spec.require) .{ .required = session.identity } else .{
            .optional = session.identity,
        };
    }
    const options: tls_conn.Options = .{
        .io = h.io,
        .fd = session.fd,
        .anchor = h.pki.ca.public_key.toBytes(),
        .server_name = spec.name,
        .client_auth = auth,
    };
    h.conn.open(&options, h.diag) catch |err| switch (err) {
        error.Refused => return false,
        else => return err,
    };
    return true;
}

fn end_in(h: *Harness, ms: u64) u64 {
    return peer_stream.boot_ms(h.io) + ms;
}

/// Reads until `want` bytes are in `out`; the error of the read otherwise.
fn read_exactly(h: *Harness, out: []u8, ms: u64) tls_conn.Error!void {
    var have: usize = 0;
    const end = end_in(h, ms);
    while (have < out.len) have += try h.conn.read(out[have..], end, h.diag);
}

/// Writes `text` and flushes it.
fn send_text(h: *Harness, text: []const u8) tls_conn.Error!void {
    try h.conn.write(text, end_in(h, step_ms), h.diag);
    try h.conn.flush(end_in(h, step_ms), h.diag);
}

// ---- Cases: the table ------------------------------------------------------------------------

const Expect = union(enum) {
    accepted,
    /// Refused with this code, and a message that holds `text`.
    refused: struct {
        code: Code,
        text: []const u8,
        /// Java only: the JVM's own `FAILED` line holds this. The alert alone cannot tell its
        /// refusals apart (they all say certificate_unknown).
        says: []const u8 = "",
    },
};

const Case = struct {
    name: []const u8,
    server: ServerSpec,
    client: ClientSpec = .{},
    expect: Expect,
};

fn refused(code: Code, text: []const u8) Expect {
    return .{ .refused = .{ .code = code, .text = text } };
}

fn refused_says(code: Code, text: []const u8, says: []const u8) Expect {
    return .{ .refused = .{ .code = code, .text = text, .says = says } };
}

fn both(
    comptime name: []const u8,
    server: ServerSpec,
    client: ClientSpec,
    expect: [2]Expect,
) [2]Case {
    var openssl = server;
    openssl.kind = .openssl;
    var java = server;
    java.kind = .java;
    return .{
        .{ .name = "openssl " ++ name, .server = openssl, .client = client, .expect = expect[0] },
        .{ .name = "java " ++ name, .server = java, .client = client, .expect = expect[1] },
    };
}

const cases = accepted_cases ++ server_refuses ++ client_refuses ++ other_refusals;

const accepted_cases = both("accepted", .{ .kind = .openssl }, .{}, .{ .accepted, .accepted });

const server_refuses =
    both("refuses a certificate from another CA", .{ .kind = .openssl }, .{ .cert = .other_ca }, .{
        refused(.E0814, "unknown_ca"),
        refused_says(.E0814, "certificate_unknown", "unable to find valid certification path"),
    }) ++
    both("refuses an expired certificate", .{ .kind = .openssl }, .{ .cert = .expired }, .{
        refused(.E0814, "certificate_expired"),
        refused_says(.E0814, "certificate_unknown", "validity check failed"),
    }) ++
    both("refuses a client with no certificate", .{ .kind = .openssl }, .{ .cert = .none }, .{
        refused(.E0814, "certificate_required"), refused(.E0814, "certificate_required"),
    }) ++
    [1]Case{.{
        .name = "java refuses another job (the allow-list)",
        .server = .{ .kind = .java, .allow = spiffe_id },
        .client = .{ .cert = .other_job },
        .expect = refused_says(.E0814, "certificate_unknown", "is not on the allow-list"),
    }};

const client_refuses =
    both("server chain from another CA", .{ .kind = .openssl, .cert = .other_ca }, .{}, .{
        refused(.E0810, "not the pinned CA"), refused(.E0810, "not the pinned CA"),
    }) ++
    both("expired server certificate", .{ .kind = .openssl, .cert = .expired }, .{}, .{
        refused(.E0811, "has expired"), refused(.E0811, "has expired"),
    }) ++
    both("server certificate for another name", .{ .kind = .openssl, .cert = .wrong_name }, .{}, .{
        refused(.E0812, "names other.botpike.com"), refused(.E0812, "names other.botpike.com"),
    }) ++
    both("server that does not ask for a certificate", .{ .kind = .openssl, .ask = false }, .{}, .{
        refused(.E0814, "did not ask for a client certificate"),
        refused(.E0814, "did not ask for a client certificate"),
    });

const other_refusals = [_]Case{.{
    .name = "openssl TLS 1.2 server (no downgrade)",
    .server = .{ .kind = .openssl, .tls12 = true },
    .expect = refused(.E0813, "protocol_version"),
}};

// ---- Running a case --------------------------------------------------------------------------

/// What the client saw: the connection worked, or it was refused with this code.
const Seen = union(enum) { accepted, refused: Code };

/// Opens, then sends a line and reads: a TLS 1.3 server that rejects the client's certificate
/// says so only after the handshake, so the alert arrives on the first read.
fn attempt(h: *Harness, session: *Session, server: *Server, spec: ClientSpec) !Seen {
    if (!try open_session(h, session, server.port, spec)) return .{ .refused = h.diag.code.? };
    send_text(h, "hello\n") catch |err| {
        if (err == error.Refused) return .{ .refused = h.diag.code.? };
        return err;
    };
    return try exchange(h, server);
}

fn exchange(h: *Harness, server: *Server) !Seen {
    var reply: [16]u8 = undefined;
    const want: []const u8 = switch (server.kind) {
        .java => "echo:hello\n",
        .openssl => "world\n",
    };
    // A server that rejected our certificate never reads "hello": its alert is on the wire.
    if (server.kind == .openssl and h.wait_log(server, "hello", 1500)) {
        try h.send(server, "world\n");
    }
    read_exactly(h, reply[0..want.len], step_ms) catch |err| switch (err) {
        error.Refused => return .{ .refused = h.diag.code.? },
        error.Timeout => return error.ServerSilent,
        else => return err,
    };
    if (!std.mem.eql(u8, reply[0..want.len], want)) return error.WrongReply;
    return .accepted;
}

fn run_case(h: *Harness, case: *const Case) !void {
    var server = try start_server(h, case.server);
    defer server.stop(h.io);
    var session: Session = undefined;
    defer if (session.fd != 0) session.close_fd();
    session.fd = 0;
    const seen = try attempt(h, &session, &server, case.client);
    var buffer: [300]u8 = undefined;
    switch (case.expect) {
        .accepted => {
            try h.check(seen == .accepted, "refused: {s}", .{describe(h, &buffer)});
            try check_identity(h, &server, spiffe_id);
            try close_clean(h, &server);
        },
        .refused => |want| {
            try h.check(seen == .refused, "accepted, expected ZC-{s}", .{@tagName(want.code)});
            const got = describe(h, &buffer);
            try h.check(h.diag.code.? == want.code, "got {s}, expected ZC-{s}", .{
                got, @tagName(want.code),
            });
            const found = std.mem.find(u8, got, want.text) != null;
            try h.check(found, "message {s} lacks \"{s}\"", .{ got, want.text });
            if (case.server.kind == .java) try check_java_says(h, &server, want.says);
            h.say("      -> {s}", .{got});
        },
    }
}

/// The JVM's reason for a refusal, from its `FAILED` line.
fn check_java_says(h: *Harness, server: *Server, says: []const u8) !void {
    if (says.len == 0) return;
    try h.check(h.wait_log(server, "FAILED", step_ms), "the JVM printed no FAILED line", .{});
    const line = h.log_line(server, "FAILED") orelse return;
    try h.check(std.mem.find(u8, line, says) != null, "the JVM said {s}, not \"{s}\"", .{
        line, says,
    });
}

/// The identity the server read from our certificate, against what we put in it: the SPIFFE id
/// `id` and the extension's fields.
fn check_identity(h: *Harness, server: *Server, id: []const u8) !void {
    const scratch = h.scratch.allocator();
    const digest = std.fmt.bytesToHex(identity.image_digest, .lower);
    const expected = try std.fmt.allocPrint(
        scratch,
        "spiffe={s} version=1 digest={s} epoch={d} labels=app=broker;env=prod",
        .{ id, digest, identity.placement_epoch },
    );
    switch (server.kind) {
        .java => {
            try h.check(h.wait_log(server, "CONN ", step_ms), "the JVM saw no connection", .{});
            const line = h.log_line(server, "CONN ").?;
            const read = line["CONN ".len..];
            try h.check(std.mem.eql(u8, read, expected), "the JVM read {s}", .{line});
        },
        .openssl => try check_openssl_view(h, server, id, expected),
    }
}

/// OpenSSL prints the certificate it was given. `openssl x509` reads the SPIFFE id; the Java
/// decoder reads the private extension (OpenSSL has no name for it).
fn check_openssl_view(h: *Harness, server: *Server, id: []const u8, expected: []const u8) !void {
    const scratch = h.scratch.allocator();
    const log = h.log_text(server);
    const marker = std.mem.find(u8, log, "Client certificate") orelse
        return h.check(false, "s_server printed no client certificate", .{});
    const begin_text = "-----BEGIN CERTIFICATE-----";
    const end_text = "-----END CERTIFICATE-----";
    const begin_at = std.mem.find(u8, log[marker..], begin_text) orelse
        return h.check(false, "s_server's client certificate has no BEGIN line yet", .{});
    const begin = begin_at + marker;
    const end_at = std.mem.find(u8, log[begin..], end_text) orelse
        return h.check(false, "s_server's client certificate has no END line yet", .{});
    const end = end_at + begin + end_text.len;
    try h.write_file("seen.pem", try std.fmt.allocPrint(scratch, "{s}\n", .{log[begin..end]}));
    const text = try run_tool(h, &.{
        "openssl", "x509", "-in", h.path("seen.pem"), "-noout", "-text",
    });
    const uri = try std.fmt.allocPrint(scratch, "URI:{s}", .{id});
    try h.check(std.mem.find(u8, text, uri) != null, "openssl x509 shows no {s}", .{uri});
    const decoded = try run_tool(h, &.{
        h.java, "-cp", h.classes, "InteropServer", "--decode", h.path("seen.pem"),
    });
    const want = try std.fmt.allocPrint(scratch, "CERT {s}", .{expected});
    try h.check(std.mem.eql(u8, std.mem.trim(u8, decoded, "\n"), want), "decoded {s}", .{decoded});
}

fn run_tool(h: *Harness, argv: []const []const u8) ![]const u8 {
    const result = try std.process.run(h.scratch.allocator(), h.io, .{
        .argv = argv,
        .timeout = tool_timeout,
    });
    if (!result.term.success()) return error.ToolFailed;
    return result.stdout;
}

/// Our `close_notify` is understood: the Java server ends the stream cleanly, s_server says DONE.
fn close_clean(h: *Harness, server: *Server) !void {
    h.conn.close(end_in(h, step_ms), h.diag) catch {};
    const marker = switch (server.kind) {
        .java => "CLOSED clean",
        .openssl => "DONE",
    };
    try h.check(h.wait_log(server, marker, step_ms), "the server never saw our close_notify", .{});
}

// ---- Scenarios: streams, KeyUpdate and truncation ----------------------------------------------

const Scenario = struct {
    name: []const u8,
    run: *const fn (*Harness) anyerror!void,
};

const scenarios = [_]Scenario{
    .{ .name = "openssl truncation is ZC-E0816", .run = truncation },
    .{ .name = "java server-sent events", .run = sse_java },
    .{ .name = "openssl server-sent events", .run = sse_openssl },
    .{ .name = "openssl KeyUpdate both ways", .run = key_update_openssl },
    .{ .name = "java bulk across a KeyUpdate", .run = bulk_java },
};

/// A started server and an open session, both stopped by `hang_up`.
const Live = struct {
    server: Server,
    session: Session,
    started: bool,
};

fn go_live(h: *Harness, live: *Live, spec: ServerSpec) !void {
    live.started = false;
    live.session.fd = 0;
    live.server = try start_server(h, spec);
    live.started = true;
    const open = try open_session(h, &live.session, live.server.port, .{});
    var buffer: [300]u8 = undefined;
    try h.check(open, "refused: {s}", .{describe(h, &buffer)});
}

fn hang_up(h: *Harness, live: *Live) void {
    if (live.started) live.server.stop(h.io);
    if (live.session.fd != 0) live.session.close_fd();
}

/// Reads until the bytes read end in `terminator`.
fn read_until(h: *Harness, buffer: []u8, terminator: []const u8, ms: u64) ![]const u8 {
    var have: usize = 0;
    const end = end_in(h, ms);
    while (!std.mem.endsWith(u8, buffer[0..have], terminator)) {
        if (have == buffer.len) return error.EventTooLong;
        have += try h.conn.read(buffer[have..], end, h.diag);
    }
    return buffer[0..have];
}

/// s_server prints what the client sent and sends what is typed on its stdin.
fn openssl_hello(h: *Harness, live: *Live) !void {
    try send_text(h, "hello\n");
    try h.check(h.wait_log(&live.server, "hello", step_ms), "s_server never read hello", .{});
    try h.send(&live.server, "world\n");
    var reply: [6]u8 = undefined;
    try read_exactly(h, &reply, step_ms);
    try h.check(std.mem.eql(u8, &reply, "world\n"), "the reply was {s}", .{&reply});
}

fn truncation(h: *Harness) !void {
    var live: Live = undefined;
    defer hang_up(h, &live);
    try go_live(h, &live, .{ .kind = .openssl });
    try openssl_hello(h, &live);
    live.server.stop(h.io); // No close_notify: the connection just ends.
    var byte: [1]u8 = undefined;
    if (h.conn.read(&byte, end_in(h, step_ms), h.diag)) |_| {
        return h.check(false, "a read returned data after the server died", .{});
    } else |err| {
        try h.check(err == error.Refused, "the read ended with {s}", .{@errorName(err)});
    }
    var buffer: [300]u8 = undefined;
    try h.check(h.diag.code == .E0816, "got {s}", .{describe(h, &buffer)});
}

fn sse_java(h: *Harness) !void {
    var live: Live = undefined;
    defer hang_up(h, &live);
    try go_live(h, &live, .{ .kind = .java, .mode = .sse });
    try send_text(h, "go\n");
    try sse_events(h, &live, false);
    try close_clean(h, &live.server);
}

fn sse_openssl(h: *Harness) !void {
    var live: Live = undefined;
    defer hang_up(h, &live);
    try go_live(h, &live, .{ .kind = .openssl });
    try sse_events(h, &live, true);
    try close_clean(h, &live.server);
}

/// Twenty events 100 ms apart arrive in order, one at a time, each soon after it was sent. With
/// `pushed` the harness plays the server's part through s_server's stdin.
fn sse_events(h: *Harness, live: *Live, pushed: bool) !void {
    var prompt: u32 = 0;
    var first: u64 = 0;
    var last: u64 = 0;
    for (0..events_count) |index| {
        if (pushed) {
            var line: [64]u8 = undefined;
            const text = try std.fmt.bufPrint(&line, "data: {d} {d}\n", .{
                index, peer_stream.wall_ms(h.io),
            });
            try h.send(&live.server, text);
        }
        var buffer: [64]u8 = undefined;
        const event = try read_until(h, &buffer, if (pushed) "\n" else "\n\n", step_ms);
        const now = peer_stream.wall_ms(h.io);
        var fields = std.mem.splitScalar(u8, std.mem.trim(u8, event, "\n"), ' ');
        const label = fields.next() orelse "";
        try h.check(std.mem.eql(u8, label, "data:"), "event {d}: {s}", .{ index, event });
        const number = try std.fmt.parseInt(usize, fields.next() orelse "", 10);
        const sent = try std.fmt.parseInt(u64, fields.next() orelse "", 10);
        try h.check(number == index, "event {d} arrived as {d}", .{ index, number });
        if (now -| sent < 80) prompt += 1;
        if (index == 0) first = peer_stream.boot_ms(h.io);
        last = peer_stream.boot_ms(h.io);
        if (pushed) h.sleep_ms(100);
    }
    try h.check(prompt >= 15, "only {d} of 20 events arrived within 80 ms", .{prompt});
    try h.check(last - first >= 1500, "the events arrived within {d} ms", .{last - first});
}

fn key_update_openssl(h: *Harness) !void {
    var live: Live = undefined;
    defer hang_up(h, &live);
    try go_live(h, &live, .{ .kind = .openssl, .messages = true });
    try openssl_hello(h, &live);
    try h.send(&live.server, "K\n"); // A KeyUpdate that asks for ours.
    const sent = ">>> TLS 1.3, Handshake [length 0005], KeyUpdate";
    try h.check(h.wait_log(&live.server, sent, step_ms), "s_server sent no KeyUpdate", .{});
    try h.send(&live.server, "later\n");
    var reply: [6]u8 = undefined;
    try read_exactly(h, &reply, step_ms);
    try h.check(std.mem.eql(u8, &reply, "later\n"), "after the update: {s}", .{&reply});
    try send_text(h, "back\n");
    try h.check(h.wait_log(&live.server, "back", step_ms), "s_server never read back", .{});
    // Ours, received: the message that proves the client answered with a KeyUpdate of its own.
    const received = "<<< TLS 1.3, Handshake [length 0005], KeyUpdate";
    const answered = h.wait_log(&live.server, received, step_ms);
    try h.check(answered, "s_server received no KeyUpdate: ours did not answer", .{});
    try close_clean(h, &live.server);
}

fn bulk_java(h: *Harness) !void {
    var live: Live = undefined;
    defer hang_up(h, &live);
    try go_live(h, &live, .{ .kind = .java, .mode = .bulk, .key_limit = true });
    try send_text(h, "go\n");
    var chunk: [16384]u8 = undefined;
    var offset: u32 = 0;
    const end = end_in(h, 60_000);
    while (offset < bulk_bytes) {
        const count = try h.conn.read(&chunk, end, h.diag);
        for (chunk[0..count], 0..) |byte, index| {
            const want: u8 = @intCast((offset + index) % 251);
            try h.check(byte == want, "byte {d} is {d}, not {d}", .{ offset + index, byte, want });
        }
        offset += @intCast(count);
    }
    try send_text(h, "done\n");
    var reply: [10]u8 = undefined;
    try read_exactly(h, &reply, step_ms);
    try h.check(std.mem.eql(u8, &reply, "bulk done\n"), "the reply was {s}", .{&reply});
    try h.check(h.wait_log(&live.server, "BULK client sent", step_ms), "the JVM saw no data", .{});
    // Not "KeyUpdate" alone: the debug output echoes the keyLimits property at startup.
    const produced = "Produced KeyUpdate post-handshake message";
    const updated = h.wait_log(&live.server, produced, step_ms);
    try h.check(updated, "the JVM never sent a KeyUpdate", .{});
    try close_clean(h, &live.server);
}

// ---- The relay's job certificate (B4) --------------------------------------------------------

/// The relay's connect and handshake bound in these cases: it also bounds the wait for a
/// `relay.crt` that never comes.
const relay_timeout_ms: u32 = 5000;

const RelayExpect = union(enum) {
    /// Bytes cross both ways through the relay, and the server read this SPIFFE id and the
    /// extension exactly.
    accepted: []const u8,
    /// The server refused the handshake: `relay.log` has one line, ZC-E0814 holding `text`, the
    /// job's connection is closed, and (Java) the JVM's `FAILED` line holds `says`.
    refused: struct { text: []const u8, says: []const u8 = "" },
    /// No `relay.crt`: the relay never dials (ZC-E0705), closes the job's connection, and the
    /// server sees no connection at all.
    no_dial,
};

const RelayCase = struct {
    name: []const u8,
    kind: ServerKind,
    cert: JobCert,
    expect: RelayExpect,
};

fn relay_both(comptime name: []const u8, cert: JobCert, expect: [2]RelayExpect) [2]RelayCase {
    return .{
        .{ .name = "openssl relay " ++ name, .kind = .openssl, .cert = cert, .expect = expect[0] },
        .{ .name = "java relay " ++ name, .kind = .java, .cert = cert, .expect = expect[1] },
    };
}

fn relay_refused(text: []const u8, says: []const u8) RelayExpect {
    return .{ .refused = .{ .text = text, .says = says } };
}

const relay_cases =
    relay_both("accepted: the job certificate", .good, .{
        .{ .accepted = relay_job_id }, .{ .accepted = relay_job_id },
    }) ++
    [2]RelayCase{
        .{
            // s_server has no SPIFFE allow-list: what it can do is show whom it let in.
            .name = "openssl relay another job's certificate is seen as that job",
            .kind = .openssl,
            .cert = .other_job,
            .expect = .{ .accepted = other_job_id },
        },
        .{
            .name = "java relay refuses another job's certificate (the allow-list)",
            .kind = .java,
            .cert = .other_job,
            .expect = relay_refused("certificate_unknown", "is not on the allow-list"),
        },
    } ++
    relay_both("refuses an expired job certificate", .expired, .{
        relay_refused("certificate_expired", ""),
        relay_refused("certificate_unknown", "validity check failed"),
    }) ++
    relay_both("refuses a job certificate from another CA", .other_ca, .{
        relay_refused("unknown_ca", ""),
        relay_refused("certificate_unknown", "unable to find valid certification path"),
    }) ++
    relay_both("without a job certificate never dials", .none, .{ .no_dial, .no_dial });

/// The container's directory as the relay sees it: `relay.crt` (when the case has one) and
/// `relay.log`.
const RelayDir = struct {
    dir: std.Io.Dir,
    path: []const u8,
    log: [:0]const u8,
};

fn run_relay_case(h: *Harness, case: *const RelayCase) !void {
    const pin: ?[]const u8 = if (case.kind == .java) relay_job_id else null;
    var server = try start_server(h, .{ .kind = case.kind, .allow = pin });
    defer server.stop(h.io);
    const before = h.log_text(&server);
    var place = try relay_dir(h);
    defer place.dir.close(h.io);
    // The agent's part: the certificate the server issued, as `relay.crt` (DER).
    if (h.pki.job_cert(case.cert)) |certificate| try place.dir.writeFile(h.io, .{
        .sub_path = agent_records.file_relay_certificate,
        .data = certificate.slice(),
    });
    const relay = try start_relay(h, &server, &place);
    defer relay.stop();
    // The job's part: a plain connection to the relay's loopback port.
    const job_fd = try relay_module.dial(relay.port);
    defer _ = std.os.linux.close(job_fd);
    switch (case.expect) {
        .accepted => |id| try relay_accepts(h, &server, &place, job_fd, id),
        .refused => |want| try relay_refuses(h, &server, &place, job_fd, want.text, want.says),
        .no_dial => try relay_never_dials(h, &server, &place, job_fd, before),
    }
}

fn relay_dir(h: *Harness) !RelayDir {
    const scratch = h.scratch.allocator();
    const path = try std.fmt.allocPrint(scratch, "{s}/relay-{d}", .{ h.work, h.cases });
    try std.Io.Dir.cwd().createDirPath(h.io, path);
    return .{
        .dir = try std.Io.Dir.cwd().openDir(h.io, path, .{}),
        .path = path,
        .log = try std.fmt.allocPrintSentinel(scratch, "{s}/relay.log", .{path}, 0),
    };
}

/// The real relay, as the supervisor runs it: secured with the run's key, its upstream the
/// stock server, which it checks against the CA that signed the server's certificate.
fn start_relay(h: *Harness, server: *const Server, place: *const RelayDir) !*relay_module.Relay {
    const upstream: relay_module.Upstream = .{ .host = "127.0.0.1", .port = server.port };
    const relay = try relay_module.Relay.open(h.gpa, h.io, upstream, place.log);
    errdefer relay.stop();
    const tls: relay_tls.Tls = .{
        .server_name = server_name,
        .anchor = h.pki.ca.public_key.toBytes(),
    };
    try relay.secure(tls, h.pki.relay_key, place.dir.handle);
    relay.limits.connect_timeout_ms = relay_timeout_ms;
    try relay.run();
    return relay;
}

fn relay_log(h: *Harness, place: *const RelayDir) []const u8 {
    const limit: std.Io.Limit = .limited(64 << 10);
    return std.Io.Dir.cwd().readFileAlloc(h.io, place.log, h.scratch.allocator(), limit) catch "";
}

/// Reads exactly `out.len` bytes from the job's side of the relay.
fn job_read(h: *Harness, fd: std.posix.fd_t, out: []u8) !void {
    var have: usize = 0;
    while (have < out.len) {
        const got = relay_module.receive(fd, out[have..], @intCast(step_ms)) orelse
            return h.check(false, "the job read nothing in {d} ms", .{step_ms});
        try h.check(got > 0, "the relay closed the job's connection after {d} bytes", .{have});
        have += got;
    }
}

fn relay_accepts(
    h: *Harness,
    server: *Server,
    place: *const RelayDir,
    job_fd: std.posix.fd_t,
    id: []const u8,
) !void {
    const line = "hello\n";
    const sent = std.os.linux.write(job_fd, line, line.len);
    try h.check(sent == line.len, "the job could not write to the relay", .{});
    const want: []const u8 = switch (server.kind) {
        .java => "echo:hello\n",
        .openssl => "world\n",
    };
    if (server.kind == .openssl) {
        const read = h.wait_log(server, "hello", step_ms);
        try h.check(read, "s_server never read the job's line", .{});
        try h.send(server, "world\n");
    }
    var reply: [16]u8 = undefined;
    const got = reply[0..want.len];
    try job_read(h, job_fd, got);
    try h.check(std.mem.eql(u8, got, want), "the job read {s}", .{got});
    try check_identity(h, server, id);
    // The job's end: the relay sends `close_notify`, and the server sees a clean end.
    _ = std.os.linux.shutdown(job_fd, std.os.linux.SHUT.WR);
    const marker = switch (server.kind) {
        .java => "CLOSED clean",
        .openssl => "DONE",
    };
    try h.check(h.wait_log(server, marker, step_ms), "the server never saw the relay's end", .{});
    const log = relay_log(h, place);
    try h.check(log.len == 0, "relay.log says {s}", .{log});
}

/// The job waits for the relay to end its connection, with nothing from upstream.
fn job_closed(h: *Harness, job_fd: std.posix.fd_t, ms: u64) !void {
    var buffer: [64]u8 = undefined;
    const got = relay_module.receive(job_fd, &buffer, @intCast(ms)) orelse
        return h.check(false, "the relay kept the job's connection open {d} ms", .{ms});
    try h.check(got == 0, "the job read {d} bytes: {s}", .{ got, buffer[0..got] });
}

fn relay_refuses(
    h: *Harness,
    server: *Server,
    place: *const RelayDir,
    job_fd: std.posix.fd_t,
    text: []const u8,
    says: []const u8,
) !void {
    try job_closed(h, job_fd, step_ms);
    const log = std.mem.trimEnd(u8, relay_log(h, place), "\n");
    try h.check(std.mem.startsWith(u8, log, "ZC-E0814 "), "relay.log says {s}", .{log});
    try h.check(std.mem.findScalar(u8, log, '\n') == null, "relay.log has more: {s}", .{log});
    const named = std.mem.find(u8, log, text) != null;
    try h.check(named, "relay.log lacks \"{s}\": {s}", .{ text, log });
    if (server.kind == .java) try check_java_says(h, server, says);
    h.say("      -> relay.log: {s}", .{log});
}

fn relay_never_dials(
    h: *Harness,
    server: *Server,
    place: *const RelayDir,
    job_fd: std.posix.fd_t,
    before: []const u8,
) !void {
    try job_closed(h, job_fd, relay_timeout_ms + step_ms);
    const log = std.mem.trimEnd(u8, relay_log(h, place), "\n");
    const waited = std.mem.find(u8, log, "had not arrived") != null;
    try h.check(std.mem.startsWith(u8, log, "ZC-E0705 ") and waited, "relay.log says {s}", .{log});
    // A connection, even one that never finished a handshake, would put a line in the log.
    h.sleep_ms(500);
    const after = h.log_text(server);
    try h.check(std.mem.eql(u8, before, after), "the server saw a connection: {s}", .{
        after[@min(before.len, after.len)..],
    });
    h.say("      -> relay.log: {s}", .{log});
}

fn finish(h: *Harness, name: []const u8, result: anyerror!void) void {
    h.cases += 1;
    result catch |err| {
        h.failures += 1;
        const why = if (err == error.CaseFailed) h.why[0..h.why_len] else @errorName(err);
        h.say("FAIL  {s}: {s}", .{ name, why });
        return;
    };
    h.say("ok    {s}", .{name});
}

pub fn main(init: std.process.Init) u8 {
    const io = init.io;
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return 2;
    if (args.len != 2) {
        const usage = "usage: mtls_interop <InteropServer.java>\n";
        std.Io.File.stderr().writeStreamingAll(io, usage) catch {}; // Nowhere else to say it.
        return 2;
    }
    return run(init, args[1]) catch |err| {
        var buffer: [128]u8 = undefined;
        const text = "mtls-interop: setup failed: {s}\n";
        const line = std.fmt.bufPrint(&buffer, text, .{@errorName(err)}) catch "setup failed\n";
        std.Io.File.stdout().writeStreamingAll(io, line) catch {}; // Nowhere else to say it.
        return 2;
    };
}

fn run(init: std.process.Init, source: []const u8) !u8 {
    const gpa = init.gpa;
    const pki = try gpa.create(Pki);
    defer gpa.destroy(pki);
    const conn = try gpa.create(Conn);
    defer gpa.destroy(conn);
    const diag = try gpa.create(Diag);
    defer gpa.destroy(diag);
    var h: Harness = .{
        .io = init.io,
        .gpa = gpa,
        .arena = .init(gpa),
        .scratch = .init(gpa),
        .environ = init.environ_map,
        .work = "",
        .java = "",
        .classes = "",
        .pki = pki,
        .conn = conn,
        .diag = diag,
    };
    defer h.arena.deinit();
    defer h.scratch.deinit();
    try make_work_dir(&h);
    defer std.Io.Dir.cwd().deleteTree(h.io, h.work) catch {}; // Best effort: it is in /tmp.
    try prepare(&h, source);
    for (&cases) |*case| {
        _ = h.scratch.reset(.retain_capacity);
        h.diag.reset();
        finish(&h, case.name, run_case(&h, case));
        conn.deinit();
    }
    for (&scenarios) |scenario| {
        _ = h.scratch.reset(.retain_capacity);
        h.diag.reset();
        finish(&h, scenario.name, scenario.run(&h));
        conn.deinit();
    }
    for (&relay_cases) |*case| {
        _ = h.scratch.reset(.retain_capacity);
        finish(&h, case.name, run_relay_case(&h, case));
    }
    h.say("{d} cases, {d} failed", .{ h.cases, h.failures });
    return if (h.failures == 0) 0 else 1;
}

/// The work directory; the caller registers its removal right away.
fn make_work_dir(h: *Harness) !void {
    const arena = h.arena.allocator();
    const base = h.environ.get("TMPDIR") orelse "/tmp";
    const stamp = std.Io.Clock.real.now(h.io).toMilliseconds();
    h.work = try std.fmt.allocPrint(arena, "{s}/zcube-interop-{d}-{d}", .{
        base, std.os.linux.getpid(), stamp,
    });
    try std.Io.Dir.cwd().createDirPath(h.io, h.work);
}

/// The files the servers read, and the compiled Java.
fn prepare(h: *Harness, source: []const u8) !void {
    try find_setpriv(h);
    try find_java(h, source);
    try pki_files(h);
}

/// `setpriv` (util-linux) ties each server's life to the harness's (`spawn`); without it the
/// first case would fail with a spawn error that names nothing.
fn find_setpriv(h: *Harness) !void {
    const result = std.process.run(h.arena.allocator(), h.io, .{
        .argv = &.{ "setpriv", "--version" },
        .timeout = tool_timeout,
    }) catch {
        h.say("FAILED: `setpriv` (util-linux) is not installed; the harness needs it", .{});
        return error.NoSetpriv;
    };
    if (!result.term.success()) {
        h.say("FAILED: `setpriv --version` did not succeed; the harness needs util-linux", .{});
        return error.NoSetpriv;
    }
}

fn find_java(h: *Harness, source: []const u8) !void {
    const arena = h.arena.allocator();
    const home = h.environ.get("ZCUBE_JAVA_HOME");
    h.java = if (home) |dir| try std.fmt.allocPrint(arena, "{s}/bin/java", .{dir}) else "java";
    const javac = if (home) |dir|
        try std.fmt.allocPrint(arena, "{s}/bin/javac", .{dir})
    else
        "javac";
    const result = try std.process.run(arena, h.io, .{
        .argv = &.{ h.java, "-version" },
        .timeout = tool_timeout,
    });
    const found = std.mem.find(u8, result.stderr, "version \"" ++ java_major ++ ".") != null;
    if (!found) {
        const text = "FAILED: the JDK must be version " ++ java_major ++
            ", but `{s} -version` says: {s}";
        h.say(text, .{
            h.java, std.mem.trim(u8, result.stderr, " \n"),
        });
        return error.WrongJdk;
    }
    h.classes = h.path("classes");
    _ = try run_tool(h, &.{ javac, "-d", h.classes, source });
    // A KeyUpdate after 1 MiB, so a 3 MiB transfer crosses one.
    const props = "jdk.tls.keyLimits=AES/GCM/NoPadding KeyUpdate 1048576\n";
    try h.write_file("jdk.props", props);
}

fn pki_files(h: *Harness) !void {
    const arena = h.arena.allocator();
    try h.pki.init(peer_stream.wall_ms(h.io));
    var ca: x509.Der = .{};
    try x509.issue_ca(&ca, h.pki.ca, h.pki.window(false));
    try h.write_file("ca.pem", try pem(arena, "CERTIFICATE", ca.slice()));
    try h.write_file("server.key", try pkcs8(arena, @splat(5)));
    for (std.enums.values(ServerCert)) |which| {
        var certificate: x509.Der = .{};
        try h.pki.server(&certificate, which);
        try h.write_file(cert_file(which), try pem(arena, "CERTIFICATE", certificate.slice()));
    }
}
