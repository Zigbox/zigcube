//! The steps of `zig build demo-b7` (src/demo_b7.zig; docs/demos/b7.md). Shell code: it starts
//! processes, reads files and connects sockets.

const std = @import("std");
const assert = std.debug.assert;
const api_tls_client = @import("api_tls_client.zig");
const codes = @import("diag/codes.zig");
const constants = @import("constants.zig");
const b1 = @import("demo_b1_state.zig");
const c1 = @import("demo_c1_state.zig");
const demo_host = @import("demo_host.zig");
const diag_mod = @import("diag.zig");
const harness_tls = @import("harness_tls.zig");
const peer_files = @import("peer_files.zig");
const peer_stream = @import("peer_stream.zig");
const pem = @import("pem.zig");
const tls_conn = @import("tls_conn.zig");
const x509 = @import("x509.zig");

const Diag = diag_mod.Diag;
const Ed25519 = std.crypto.sign.Ed25519;
const Host = demo_host.Host;
const net = std.Io.net;

pub const Demo = struct {
    host: *Host,
    /// The TLS listener (`--listen`): every call the demo acts through.
    tls_port: u16 = 0,
    tls_address: []const u8 = "",
    /// The cluster CA's certificate, from the server's state directory.
    ca: []const u8 = "",
};

/// How long the agent has to join over TLS: as long as the server has to start.
const join_wait_ms: u32 = b1.start_wait_ms;
/// A call over TLS, handshake included.
const call_ms: u64 = 10_000;
const reply_bytes_max: usize = 256 * 1024;

// ---- 0. The server, its CA and two certificates ----

pub fn start(demo: *Demo) !void {
    const host = demo.host;
    host.section("0. The server makes its CA; the operator issues two certificates");
    host.say("  the demo's directory is {s}", .{host.work});
    try host.start_server(b1.start_wait_ms);
    host.say("  zcube-server is up: TLS on {s} (--listen), plain HTTP on 127.0.0.1:{d} " ++
        "(--insecure-listen, loopback: the demo reads through it and acts through TLS only)", .{
        demo.tls_address, host.port,
    });
    const state_dir = try host.path_in_work("server-state");
    demo.ca = try find_ca(host, state_dir);
    host.say("  its CA certificate: server-state/{s}", .{std.fs.path.basename(demo.ca)});
    const certs = try host.path_in_work("certs");
    try server_command(host, &.{
        "ca",      "issue-client",    "app",         "--scope", "jobs",
        "--store", host.config.store, "--state-dir", state_dir, "--out",
        certs,
    });
    try server_command(host, &.{
        "ca",      "issue-client",    "ops",         "--scope", "admin",
        "--store", host.config.store, "--state-dir", state_dir, "--out",
        certs,
    });
    try server_command(host, &.{
        "ca",          "issue-node", "node1", "--store", host.config.store,
        "--state-dir", state_dir,    "--out", certs,
    });
    try host.cli_environ.put("ZCUBE_CA", demo.ca);
    try host.cli_environ.put("ZCUBE_CERT", try host.path_in_work("certs/app.crt"));
    try host.cli_environ.put("ZCUBE_KEY", try host.path_in_work("certs/app.key"));
    host.say("$ export ZCUBE_SERVER={s} ZCUBE_CA=<the CA> ZCUBE_CERT=certs/app.crt " ++
        "ZCUBE_KEY=certs/app.key", .{demo.tls_address});
}

/// The one CA certificate the server wrote in its state directory (`harness_tls.Pki.find_ca`).
fn find_ca(host: *Host, state_dir: []const u8) ![]const u8 {
    var pki: harness_tls.Pki = .{
        .io = host.io,
        .arena = host.arena(),
        .server_exe = host.config.server_exe,
        .store = host.config.store,
        .state_dir = state_dir,
        .certs = try host.path_in_work("certs"),
    };
    const found = pki.find_ca() catch return host.fail("{s}", .{pki.said});
    return found orelse host.fail("the server wrote no CA certificate in {s}", .{state_dir});
}

/// `zcube-server <args>`, shown; it must exit 0 within `demo_host.command_timeout_ms`.
fn server_command(host: *Host, args: []const []const u8) !void {
    const argv = try host.arena().alloc([]const u8, args.len + 1);
    argv[0] = host.config.server_exe;
    @memcpy(argv[1..], args);
    host.say("$ zcube-server {s}", .{try std.mem.join(host.arena(), " ", args)});
    const result = std.process.run(host.arena(), host.io, .{
        .argv = argv,
        .stdout_limit = .limited(demo_host.output_bytes_max),
        .stderr_limit = .limited(demo_host.output_bytes_max),
        .timeout = .{ .duration = .{
            .raw = .fromMilliseconds(demo_host.command_timeout_ms),
            .clock = .awake,
        } },
    }) catch |err| {
        return host.fail("zcube-server {s} {s} did not finish: {t}", .{ args[0], args[1], err });
    };
    host.out(result.stdout);
    host.out(result.stderr);
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    try host.check(ok, "zcube-server {s} {s} succeeded", .{ args[0], args[1] });
}

// ---- 1. node1's agent joins over TLS ----

pub fn agent_joins(demo: *Demo) !void {
    const host = demo.host;
    host.section("1. node1's agent joins over TLS with its node certificate");
    const cert = try host.path_in_work("certs/node1.crt");
    const key = try host.path_in_work("certs/node1.key");
    const args = [_][]const u8{
        "--node",         "node1",
        "--server",       demo.tls_address,
        "--state-dir",    host.state,
        "--cpu-millis",   "4000",
        "--memory-bytes", "8589934592",
        "--images",       host.config.images,
        "--ca",           demo.ca,
        "--cert",         cert,
        "--key",          key,
        "--verbose",
    };
    host.say("$ zcube-agent --node node1 --server {s} --state-dir state --ca <the CA> " ++
        "--cert certs/node1.crt --key certs/node1.key ...", .{demo.tls_address});
    host.agent_starts += 1;
    host.agent = try host.spawn(host.config.agent_exe, &args, "agent-1.log");
    try host.wait_for({}, node1_ready, "node1 to register", join_wait_ms);
    try host.check(true, "node1 joined over TLS and registered (/nodes/node1)", .{});
    try host.wait_for(demo, holds_node_certificate, "node1's node.crt", join_wait_ms);
    try host.check(true, "node1's agent holds a node certificate of its own (state/node.crt)", .{});
}

fn node1_ready(_: void, host: *Host) !bool {
    return node_registered(host, "node1");
}

/// Whether `/nodes/<name>` is in the store, read through the insecure listener (the demo's jobs
/// client may not read nodes). The agent puts it on its lease once it has joined.
fn node_registered(host: *Host, name: []const u8) !bool {
    const key = try std.fmt.allocPrint(host.arena(), "/nodes/{s}", .{name});
    return key_listed(host, "/nodes/", key);
}

/// Whether `key` is in the store under `prefix`, read through the insecure listener.
fn key_listed(host: *Host, prefix: []const u8, key: []const u8) !bool {
    assert(std.mem.startsWith(u8, key, prefix));
    const path = try std.fmt.allocPrint(host.arena(), "/v1/list?prefix={s}", .{prefix});
    const listed = try host.json(path);
    if (listed != .object) return host.fail("GET /v1/list is not an object", .{});
    const kvs = listed.object.get("kvs") orelse return host.fail("no kvs in /v1/list", .{});
    if (kvs != .array) return host.fail("GET /v1/list: kvs is not an array", .{});
    for (kvs.array.items) |item| {
        if (item != .object) continue;
        const listed_key = item.object.get("key") orelse continue;
        if (listed_key == .string and std.mem.eql(u8, listed_key.string, key)) return true;
    }
    return false;
}

fn holds_node_certificate(demo: *Demo, host: *Host) !bool {
    const path = try std.fmt.allocPrint(host.arena(), "{s}/node.crt", .{host.state});
    _ = demo;
    std.Io.Dir.cwd().access(host.io, path, .{}) catch return false;
    return true;
}

// ---- 2 and 3. The jobs client ----

pub fn jobs_client(demo: *Demo) !void {
    const host = demo.host;
    host.section("2. The jobs client runs a job over TLS and cancels it");
    const run = try b1.run_job(host, "hello", &.{}, "sleep 300");
    try host.check(run.code == 0, "zcube job run hello succeeded", .{});
    try b1.wait_state(host, "hello", "running", b1.job_wait_ms);
    const cancel = try host.zcube(&.{ "job", "cancel", "hello" });
    try host.check(cancel.code == 0, "zcube job cancel hello succeeded", .{});
    const cli = try b1.wait_job(host, "hello", 12, "cancelled");
    try host.check(b1.contains(cli.out, "end: cancelled"), "hello ended cancelled", .{});
}

pub fn jobs_client_refused(demo: *Demo) !void {
    const host = demo.host;
    host.section("3. The same client may not touch services");
    try c1.write_service(host, "web", 1);
    const apply = try host.zcube(&.{ "apply", "--yes", "web.zon" });
    try host.check(apply.code != 0, "zcube apply web.zon failed", .{});
    const refused = b1.contains(apply.err, "ZC-E0822");
    try host.check(refused, "the server refused it: ZC-E0822 (the jobs scope)", .{});
    host.say("  # the same certificate, POST /v1/services by hand", .{});
    var credentials: api_tls_client.Credentials = undefined;
    defer credentials.deinit();
    var diag: Diag = undefined;
    diag.reset();
    try credentials.load(host.io, .{
        .ca = demo.ca,
        .cert = try host.path_in_work("certs/app.crt"),
        .key = try host.path_in_work("certs/app.key"),
    }, &diag);
    const posted = try call_as(demo, &credentials, "POST", "/v1/services", "{}");
    host.say("  POST /v1/services -> {s}", .{status_line(posted)});
    try host.check(b1.contains(posted, " 403 "), "the jobs client was refused it (403)", .{});
    try host.check(b1.contains(posted, "ZC-E0822"), "the refusal is ZC-E0822", .{});
    const web = try key_listed(host, "/services/", "/services/web");
    try host.check(!web, "no service web was written (/services/web is absent)", .{});
}

// ---- 4. No certificate ----

pub fn no_certificate(demo: *Demo) !void {
    const host = demo.host;
    host.section("4. A client with no certificate is refused at the handshake");
    host.say("  # a TLS 1.3 client that pins the CA and answers the server's request for a " ++
        "certificate with none, then sends GET /v1/jobs", .{});
    var credentials: api_tls_client.Credentials = undefined;
    var diag: Diag = undefined;
    diag.reset();
    try credentials.load_ca(host.io, demo.ca, api_tls_client.server_name_default, &diag);
    const log = try host.path_in_work("server-1.log");
    const mark = read_log(host, log).len;
    const got = try call_without_certificate(demo, &credentials);
    try host.check(got == .refused, "the request got no answer: {t}", .{got});
    const client_code = if (got.refused) |code| codes.full_name(code) else "the server closed";
    host.say("  the client: {s}", .{client_code});
    try host.check(got.refused == .E0814, "the client reports ZC-E0814", .{});
    const want = "tls: ZC-E0814: the client sent no certificate";
    try host.wait_for(Logged{ .path = log, .from = mark, .text = want }, logged, "the log", 5_000);
    host.say("  the server's log: {s}", .{std.mem.trim(u8, read_log(host, log)[mark..], "\n")});
    try host.check(true, "the server refused it: ZC-E0814, no certificate", .{});
}

const Called = union(enum) { answered, refused: ?codes.Code };

fn call_without_certificate(demo: *Demo, credentials: *api_tls_client.Credentials) !Called {
    const host = demo.host;
    const address = try net.IpAddress.parse("127.0.0.1", demo.tls_port);
    const stream = try address.connect(host.io, .{ .mode = .stream });
    defer stream.close(host.io);
    const conn = try host.arena().create(tls_conn.Conn);
    defer conn.deinit();
    const options: tls_conn.Options = .{
        .io = host.io,
        .fd = stream.socket.handle,
        .anchor = credentials.anchor,
        .server_name = credentials.server_name,
        .client_auth = .none,
    };
    var diag: Diag = undefined;
    diag.reset();
    const end_ms = peer_stream.boot_ms(host.io) + call_ms;
    conn.open(&options, &diag) catch return .{ .refused = diag.code };
    const head = "GET /v1/jobs HTTP/1.1\r\nHost: zcube-server\r\nConnection: close\r\n\r\n";
    conn.write(head, end_ms, &diag) catch return .{ .refused = diag.code };
    conn.flush(end_ms, &diag) catch return .{ .refused = diag.code };
    var chunk: [4096]u8 = undefined;
    const length = conn.read(&chunk, end_ms, &diag) catch return .{ .refused = diag.code };
    return if (length == 0) .{ .refused = null } else .answered;
}

const Logged = struct { path: []const u8, from: usize, text: []const u8 };

fn logged(want: Logged, host: *Host) !bool {
    const text = read_log(host, want.path);
    return b1.contains(text[@min(want.from, text.len)..], want.text);
}

fn read_log(host: *Host, path: []const u8) []const u8 {
    const limit: std.Io.Limit = .limited(16 << 20);
    return std.Io.Dir.cwd().readFileAlloc(host.io, path, host.arena(), limit) catch "";
}

// ---- 5. node1's agent, held to node1 ----

pub fn node_scope(demo: *Demo) !void {
    const host = demo.host;
    host.section("5. node1's agent credentials may not write under node2");
    host.say("  # the agent's own state/node.crt and state/peer.key, presented over TLS", .{});
    var credentials: api_tls_client.Credentials = undefined;
    try node1_credentials(demo, &credentials);
    defer credentials.deinit();
    const body = "{\"ttl_ms\":8000}";
    const theirs = try call_as(demo, &credentials, "POST", "/v1/agent/nodes/node2/lease", body);
    host.say("  POST /v1/agent/nodes/node2/lease -> {s}", .{status_line(theirs)});
    try host.check(b1.contains(theirs, " 403 "), "node1 was refused node2's lease (403)", .{});
    try host.check(b1.contains(theirs, "ZC-E0822"), "the refusal is ZC-E0822", .{});
    const own = try call_as(demo, &credentials, "GET", "/v1/agent/nodes/node1/replicas", "");
    host.say("  GET /v1/agent/nodes/node1/replicas -> {s}", .{status_line(own)});
    try host.check(b1.contains(own, " 200 "), "node1 may read its own replicas (200)", .{});
    const node2 = try node_registered(host, "node2");
    try host.check(!node2, "no node node2 was registered (/nodes/node2 is absent)", .{});
}

/// The CA of the demo, and node1's own certificate and key from the agent's state directory.
fn node1_credentials(demo: *Demo, credentials: *api_tls_client.Credentials) !void {
    const host = demo.host;
    var diag: Diag = undefined;
    diag.reset();
    try credentials.load_ca(host.io, demo.ca, api_tls_client.server_name_default, &diag);
    const path = try std.fmt.allocPrint(host.arena(), "{s}/node.crt", .{host.state});
    const text = read_log(host, path);
    var der: [constants.x509_cert_bytes_max]u8 = undefined;
    const decoded = pem.decode(text, .certificate, &der) orelse
        return host.fail("{s} is not one PEM certificate", .{path});
    var certificate: x509.Der = .{};
    certificate.start = @intCast(certificate.bytes.len - decoded.len);
    @memcpy(certificate.bytes[certificate.start..], decoded);
    const dir = try std.Io.Dir.cwd().openDir(host.io, host.state, .{});
    defer dir.close(host.io);
    var seed = (try peer_files.read_seed(host.io, dir, host.state, "peer.key", &diag)) orelse
        return host.fail("the agent has no peer.key in {s}", .{host.state});
    defer std.crypto.secureZero(u8, &seed);
    const key_pair = try Ed25519.KeyPair.generateDeterministic(seed);
    const now_ms = peer_stream.wall_ms(host.io);
    if (credentials.present(&certificate, key_pair, "node1", now_ms)) |why| {
        return host.fail("state/node.crt cannot be presented: {s}", .{why});
    }
}

/// One request over TLS as `credentials`; the raw reply.
fn call_as(
    demo: *Demo,
    credentials: *api_tls_client.Credentials,
    method: []const u8,
    path: []const u8,
    body: []const u8,
) ![]const u8 {
    const host = demo.host;
    const address = try net.IpAddress.parse("127.0.0.1", demo.tls_port);
    const stream = try address.connect(host.io, .{ .mode = .stream });
    defer stream.close(host.io);
    const head = try std.fmt.allocPrint(
        host.arena(),
        "{s} {s} HTTP/1.1\r\nHost: zcube-server\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ method, path, body.len, body },
    );
    var diag: Diag = undefined;
    diag.reset();
    const end_ms = peer_stream.boot_ms(host.io) + call_ms;
    const got = try api_tls_client.exchange(
        credentials,
        host.io,
        stream.socket.handle,
        host.arena(),
        &.{head},
        reply_bytes_max,
        api_tls_client.reply_is_whole,
        end_ms,
        &diag,
    );
    const ended = got.ending == .done;
    try host.check_quiet(ended, "{s} {s} over TLS: {t}", .{ method, path, got.ending });
    return got.reply;
}

// ---- 6. A reply longer than one TLS record ----

pub fn large_reply(demo: *Demo) !void {
    const host = demo.host;
    host.section("6. An admin reads a reply longer than one TLS record");
    host.say("  # certs/ops.crt (scope admin): GET /v1/codes, every code the server knows", .{});
    var credentials: api_tls_client.Credentials = undefined;
    defer credentials.deinit();
    var diag: Diag = undefined;
    diag.reset();
    try credentials.load(host.io, .{
        .ca = demo.ca,
        .cert = try host.path_in_work("certs/ops.crt"),
        .key = try host.path_in_work("certs/ops.key"),
    }, &diag);
    const reply = try call_as(demo, &credentials, "GET", "/v1/codes", "");
    host.say("  GET /v1/codes -> {s}", .{status_line(reply)});
    try host.check(b1.contains(reply, " 200 "), "the admin may read the codes (200)", .{});
    const split = std.mem.find(u8, reply, "\r\n\r\n") orelse
        return host.fail("GET /v1/codes: no end of head", .{});
    const length = content_length(reply[0..split]) orelse
        return host.fail("GET /v1/codes: no Content-Length", .{});
    const body = reply[split + 4 ..];
    host.say("  Content-Length {d}, body {d} bytes", .{ length, body.len });
    try host.check(length > tls_record_plaintext_max, "the reply is longer than one record", .{});
    try host.check(body.len == length, "the whole body arrived ({d} bytes)", .{body.len});
}

/// The largest plaintext of one TLS record.
const tls_record_plaintext_max: usize = 16 * 1024;

fn content_length(head: []const u8) ?usize {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], "content-length")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " ");
        return std.fmt.parseInt(usize, value, 10) catch null;
    }
    return null;
}

fn status_line(reply: []const u8) []const u8 {
    const end = std.mem.findScalar(u8, reply, '\r') orelse reply.len;
    return reply[0..end];
}

comptime {
    assert(call_ms > 0);
}
