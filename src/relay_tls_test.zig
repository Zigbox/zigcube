//! The relay over TLS (B4 slice 2) against an in-process upstream: the scripted server of
//! `tls_testpeer.zig` on a loopback port, with a server certificate of its own CA, pinning the
//! cluster CA and the job's SPIFFE ID as a stock server would. Native only: sockets, threads and
//! the real clock (the certificates are issued around it).

const std = @import("std");
const constants = @import("constants.zig");
const peer_stream = @import("peer_stream.zig");
const relay_module = @import("relay.zig");
const relay_tls = @import("relay_tls.zig");
const schedule = @import("tls_schedule.zig");
const testpeer = @import("tls_testpeer.zig");
const x509 = @import("x509.zig");
const x509_identity = @import("x509_identity.zig");
const x509_test = @import("x509_test.zig");
const agent_records = @import("agent_records.zig");
const seeds = @import("fuzz_seeds.zig");

const Ed25519 = std.crypto.sign.Ed25519;
const linux = std.os.linux;
const fd_t = linux.fd_t;
const testing = std.testing;

const upstream_name = "broker.example.com";
const cluster = "prod.example";
const job = "train-1";
const job_uri = "spiffe://prod.example/job/train-1";
const deadline_ms: u64 = 5000;

/// The relay's run certificate, as the server would issue it, and what may be wrong with it.
const Bad = enum { none, other_job, expired, other_ca };

/// One upstream server: a listener, a thread that serves one connection, and what it saw.
const Upstream = struct {
    listener: relay_module.Bound,
    upstream_key: Ed25519.KeyPair,
    upstream_ca: Ed25519.KeyPair,
    leaf: x509.Der,
    chain: [1][]const u8,
    cluster_ca: [32]u8,
    now_ms: u64,
    thread: ?std.Thread = null,
    /// Written by the thread before it returns.
    flight: ?testpeer.ClientFlight = null,
    leaf_seen: [constants.x509_cert_bytes_max]u8 = undefined,
    leaf_length: u32 = 0,
    echoed: u32 = 0,
    /// Accept, then never answer: for the cancel bound.
    silent: bool = false,
    /// For the fuzzer: each echo goes back as records of random sizes, each written in random
    /// pieces with pauses, so the relay meets half records and several records per read.
    fragments: ?std.Random = null,
    accepted: bool = false,

    fn init(up: *Upstream, cluster_ca: [32]u8, now_ms: u64) !void {
        up.* = .{
            .listener = try relay_module.listen_loopback(),
            .upstream_key = try Ed25519.KeyPair.generateDeterministic(@splat(0x31)),
            .upstream_ca = try Ed25519.KeyPair.generateDeterministic(@splat(0x32)),
            .leaf = .{},
            .chain = undefined,
            .cluster_ca = cluster_ca,
            .now_ms = now_ms,
        };
        const request: x509.ServerRequest = .{
            .dns_name = upstream_name,
            .subject_key = up.upstream_key.public_key.toBytes(),
            .lifetime = .{
                .not_before_ms = now_ms - x509_test.hour,
                .not_after_ms = now_ms + x509_test.hour,
            },
        };
        try x509.issue_server(&up.leaf, up.upstream_ca, &request);
        up.chain = .{up.leaf.slice()};
    }

    fn start(up: *Upstream) !void {
        up.thread = try std.Thread.spawn(.{}, serve, .{up});
    }

    fn join(up: *Upstream) void {
        if (up.thread) |thread| thread.join();
        up.thread = null;
        _ = linux.close(up.listener.fd);
    }

    fn tls(up: *const Upstream) relay_tls.Tls {
        return .{ .server_name = upstream_name, .anchor = up.upstream_ca.public_key.toBytes() };
    }

    fn serve(up: *Upstream) void {
        const fd = accept_one(up.listener.fd) orelse return;
        defer _ = linux.close(fd);
        up.accepted = true;
        if (up.silent) {
            var byte: [1]u8 = undefined;
            _ = receive(fd, &byte, 2000);
            return;
        }
        up.handshake_and_echo(fd) catch {};
    }

    fn handshake_and_echo(up: *Upstream, fd: fd_t) !void {
        const io = testing.io;
        var peer = testpeer.Peer.init(.{
            .certificates = &up.chain,
            .key = up.upstream_key,
            .random = @splat(0x77),
            .secret = @splat(0x55),
            .client_auth = .{ .anchor = up.cluster_ca, .now_ms = up.now_ms, .name = job_uri },
        });
        var hello: [constants.tls_client_hello_bytes_max]u8 = undefined;
        var out: [8192]u8 = undefined;
        const flight = peer.respond(try read_record(io, fd, &hello), &out);
        try peer_stream.write_all(io, fd, flight, end_in(io));
        var bytes: [constants.tls_output_bytes_max]u8 = undefined;
        var length: usize = 0;
        var count: u32 = 0;
        while (count < 3) {
            const record = try read_record(io, fd, bytes[length..]);
            length += record.len;
            if (record[0] != @backingInt(schedule.ContentType.change_cipher_spec)) count += 1;
        }
        const result = peer.accept_client_flight(bytes[0..length]);
        up.flight = result;
        const leaf = peer.client_leaf();
        @memcpy(up.leaf_seen[0..leaf.len], leaf);
        up.leaf_length = @intCast(leaf.len);
        if (result != .ok) return;
        var buffer: [constants.tls_record_ciphertext_bytes_max + 5]u8 = undefined;
        while (true) {
            const opened = try peer.open(try read_record(io, fd, &buffer));
            if (opened.content_type != .application_data) return; // close_notify
            try echo(up, &peer, fd, opened.content);
            up.echoed += @intCast(opened.content.len);
        }
    }
};

fn echo(up: *Upstream, peer: *testpeer.Peer, fd: fd_t, content: []const u8) !void {
    const io = testing.io;
    var sealed: [constants.tls_record_ciphertext_bytes_max + 5]u8 = undefined;
    const random = up.fragments orelse {
        try peer_stream.write_all(io, fd, peer.application(&sealed, content), end_in(io));
        return;
    };
    var done: usize = 0;
    while (done < content.len) {
        const take = random.intRangeAtMost(usize, 1, content.len - done);
        const record = peer.application(&sealed, content[done..][0..take]);
        done += take;
        var sent: usize = 0;
        while (sent < record.len) {
            const piece = random.intRangeAtMost(usize, 1, record.len - sent);
            try peer_stream.write_all(io, fd, record[sent..][0..piece], end_in(io));
            sent += piece;
            if (random.boolean()) {
                try io.sleep(.fromMicroseconds(random.uintLessThan(u32, 300)), .awake);
            }
        }
    }
}

fn end_in(io: std.Io) u64 {
    return peer_stream.boot_ms(io) + deadline_ms;
}

fn read_record(io: std.Io, fd: fd_t, buffer: []u8) ![]u8 {
    const end = end_in(io);
    try peer_stream.read_exact(io, fd, buffer[0..constants.tls_record_header_bytes], end);
    const length = std.mem.readInt(u16, buffer[3..5], .big);
    const total = constants.tls_record_header_bytes + length;
    try peer_stream.read_exact(io, fd, buffer[constants.tls_record_header_bytes..total], end);
    return buffer[0..total];
}

fn accept_one(listener: fd_t) ?fd_t {
    var fds = [1]linux.pollfd{.{ .fd = listener, .events = linux.POLL.IN, .revents = 0 }};
    if (linux.poll(&fds, 1, @intCast(deadline_ms)) <= 0) return null;
    const accepted = linux.accept4(listener, null, null, linux.SOCK.CLOEXEC);
    if (linux.errno(accepted) != .SUCCESS) return null;
    return @intCast(accepted);
}

fn receive(fd: fd_t, buffer: []u8, ms: i32) ?usize {
    return relay_module.receive(fd, buffer, ms);
}

/// The run's certificate, as `relay.crt`, signed for `key`.
fn issue(out: *x509.Der, key: Ed25519.KeyPair, now_ms: u64, bad: Bad) !void {
    var ca = try x509_test.ca_pair();
    if (bad == .other_ca) ca = try Ed25519.KeyPair.generateDeterministic(@splat(0xCB));
    var request = x509_test.workload_request(key.public_key.toBytes());
    request.cluster = cluster;
    request.path = .job;
    request.name = if (bad == .other_job) "train-2" else job;
    request.lifetime = if (bad == .expired)
        .{ .not_before_ms = now_ms - 3 * x509_test.hour, .not_after_ms = now_ms - x509_test.hour }
    else
        .{ .not_before_ms = now_ms - x509_test.hour, .not_after_ms = now_ms + x509_test.hour };
    try x509.issue_workload(out, ca, &request);
}

fn put_file(dir: std.Io.Dir, name: []const u8, bytes: []const u8) !void {
    try dir.writeFile(testing.io, .{ .sub_path = name, .data = bytes });
}

/// A relay to `up`, secured with a fresh key, its directory `dir`.
fn open_relay(up: *const Upstream, dir: std.Io.Dir, log: [:0]const u8) !*relay_module.Relay {
    const target: relay_module.Upstream = .{ .host = "127.0.0.1", .port = up.listener.port };
    const relay = try relay_module.Relay.open(testing.allocator, testing.io, target, log);
    errdefer relay.stop();
    const key = try Ed25519.KeyPair.generateDeterministic(@splat(0x41));
    try relay.secure(up.tls(), &key, dir.handle);
    relay.limits.connect_timeout_ms = 2000;
    return relay;
}

fn log_path(buffer: []u8, tmp: *testing.TmpDir) ![:0]const u8 {
    var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(testing.io, &dir_buffer);
    return std.fmt.bufPrintSentinel(buffer, "{s}/relay.log", .{dir_buffer[0..length]}, 0);
}

fn read_log(tmp: *testing.TmpDir, buffer: []u8) []const u8 {
    const text = tmp.dir.readFile(testing.io, "relay.log", buffer) catch return "";
    return text;
}

/// Through the relay: "ping" out, and the upstream's echo back, or the connection's end.
fn ping(port: u16) !?usize {
    const fd = try relay_module.dial(port);
    defer _ = linux.close(fd);
    _ = linux.write(fd, "ping", 4);
    var buffer: [16]u8 = undefined;
    const got = receive(fd, &buffer, @intCast(deadline_ms)) orelse return null;
    if (got == 4) try testing.expectEqualStrings("ping", buffer[0..4]);
    return got;
}

const Case = struct { flight: ?testpeer.ClientFlight, got: ?usize, log: [512]u8 };

fn run_case(bad: Bad) !Case {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const now = peer_stream.wall_ms(testing.io);
    const ca = try x509_test.ca_pair();
    var up: Upstream = undefined;
    try up.init(ca.public_key.toBytes(), now);
    try up.start();
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const relay = try open_relay(&up, tmp.dir, try log_path(&path, &tmp));
    var certificate: x509.Der = .{};
    try issue(&certificate, relay.credential.?.key, now, bad);
    try put_file(tmp.dir, agent_records.file_relay_certificate, certificate.slice());
    try relay.run();
    const got = try ping(relay.port);
    relay.stop();
    up.join();
    var result: Case = .{
        .flight = up.flight,
        .got = got,
        .log = @splat(0),
    };
    _ = read_log(&tmp, &result.log);
    if (bad == .none) {
        // The fields a stock upstream reads: the job's URI, the image digest, the epoch, labels.
        const leaf = up.leaf_seen[0..up.leaf_length];
        var detail: x509.Detail = .{};
        const parsed = try x509.parse_profile(leaf, .cluster, &detail);
        try testing.expectEqualStrings(job_uri, parsed.name.of(leaf));
        const decoded = try x509_identity.decode(parsed.identity.of(leaf));
        const expected = x509_test.sample_identity();
        try testing.expectEqualSlices(u8, &expected.image_digest, &decoded.image_digest);
        try testing.expectEqual(expected.placement_epoch, decoded.placement_epoch);
        try testing.expectEqual(@as(u32, @intCast(expected.labels.len)), decoded.labels_count);
        try testing.expectEqual(@as(u32, 4), up.echoed);
    }
    return result;
}

test "the relay presents the run's certificate and the upstream reads the job from it" {
    // Goal: B4's first promise: the upstream gets a TLS connection whose client certificate
    // names the run (SPIFFE ID, image digest, epoch, labels), and bytes cross both ways.
    // Method: the scripted upstream pins the cluster CA and the job's URI, then echoes.
    const result = try run_case(.none);
    try testing.expectEqual(@as(?testpeer.ClientFlight, .ok), result.flight);
    try testing.expectEqual(@as(?usize, 4), result.got);
}

test "an upstream that pins the CA and the job refuses each bad certificate" {
    // Goal: another job's certificate, an expired one and one from another CA are each refused
    // by the upstream, and the job's connection ends with nothing from upstream.
    for ([_]Bad{ .other_job, .expired, .other_ca }) |bad| {
        const result = try run_case(bad);
        try testing.expectEqual(@as(?testpeer.ClientFlight, .bad_certificate), result.flight);
        try testing.expect(result.got == null or result.got.? == 0);
    }
}

test "without a certificate the relay sends nothing upstream" {
    // Goal: the fourth case, no certificate: when the server refused one (`relay.refused`), the
    // relay never dials, logs ZC-E0706, and closes the job's connection. The relay has no path
    // that dials without a certificate, so an upstream that pins the CA never meets an empty
    // Certificate from it; that such an upstream refuses one is `tls_client_test`'s "a client
    // without a usable certificate says so when the server asks" (same `testpeer`, required).
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const now = peer_stream.wall_ms(testing.io);
    const ca = try x509_test.ca_pair();
    var up: Upstream = undefined;
    try up.init(ca.public_key.toBytes(), now);
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const relay = try open_relay(&up, tmp.dir, try log_path(&path, &tmp));
    try put_file(tmp.dir, agent_records.file_relay_refused, "");
    try relay.run();
    const got = try ping(relay.port);
    relay.stop();
    try testing.expect(got == null or got.? == 0);
    var fds = [1]linux.pollfd{.{ .fd = up.listener.fd, .events = linux.POLL.IN, .revents = 0 }};
    try testing.expectEqual(@as(usize, 0), linux.poll(&fds, 1, 0));
    up.join();
    var buffer: [512]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, read_log(&tmp, &buffer), "ZC-E0706") != null);
}

test "a certificate for another key is not taken" {
    // Goal: nothing the container's directory holds can change whose key signs: a certificate
    // that is not for the run's key leaves the credential waiting.
    const key = try Ed25519.KeyPair.generateDeterministic(@splat(0x41));
    const other = try Ed25519.KeyPair.generateDeterministic(@splat(0x42));
    const now = peer_stream.wall_ms(testing.io);
    var certificate: x509.Der = .{};
    try issue(&certificate, other, now, .none);
    var credential: relay_tls.Credential = .init(&key);
    try testing.expectError(error.NotTheRunKey, credential.take(certificate.slice()));
    try testing.expectEqual(relay_tls.State.waiting, credential.state.load(.acquire));
    try issue(&certificate, key, now, .none);
    try credential.take(certificate.slice());
    try testing.expectEqual(relay_tls.State.ready, credential.state.load(.acquire));
}

test "stop ends a connection waiting in the handshake within the cancel bound" {
    // Goal: `relay_cancel_ms_max`: an upstream that accepts and never answers holds the
    // connection in the handshake's wait (up to the connect timeout); `stop` must not wait for
    // it. Method: time `stop` while the handshake waits.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const now = peer_stream.wall_ms(testing.io);
    const ca = try x509_test.ca_pair();
    var up: Upstream = undefined;
    try up.init(ca.public_key.toBytes(), now);
    up.silent = true;
    try up.start();
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const relay = try open_relay(&up, tmp.dir, try log_path(&path, &tmp));
    relay.limits.connect_timeout_ms = constants.relay_connect_timeout_ms;
    var certificate: x509.Der = .{};
    try issue(&certificate, relay.credential.?.key, now, .none);
    try put_file(tmp.dir, agent_records.file_relay_certificate, certificate.slice());
    try relay.run();
    const fd = try relay_module.dial(relay.port);
    defer _ = linux.close(fd);
    var waited: u32 = 0;
    while (!up.accepted and waited < deadline_ms) : (waited += 10) sleep_ms(10);
    try testing.expect(up.accepted);
    sleep_ms(constants.relay_poll_ms); // Into the handshake's wait.
    const started = monotonic_ms();
    relay.stop();
    const took = monotonic_ms() - started;
    up.join();
    try testing.expect(took <= constants.relay_cancel_ms_max);
}

fn sleep_ms(ms: u64) void {
    const request: linux.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * 1_000_000),
    };
    _ = linux.nanosleep(&request, null);
}

fn monotonic_ms() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * 1000 + @as(u64, @intCast(now.nsec)) / 1_000_000;
}

// ---- Fuzz: the copy loop over TLS records ----------------------------------------------------

const fuzz_bytes_max = 3 * constants.relay_buffer_bytes;

/// One seeded run: the job writes a random stream in random chunks and reads the echo in random
/// short reads; the upstream answers in records of random sizes, written in random pieces. The
/// job must get back exactly what it sent, in order.
fn tls_copy_once(seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const now = peer_stream.wall_ms(testing.io);
    const ca = try x509_test.ca_pair();
    var up: Upstream = undefined;
    try up.init(ca.public_key.toBytes(), now);
    var upstream_prng = std.Random.DefaultPrng.init(seed ^ 0x9E3779B97F4A7C15);
    up.fragments = upstream_prng.random();
    try up.start();
    defer up.join();
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const relay = try open_relay(&up, tmp.dir, try log_path(&path, &tmp));
    defer relay.stop();
    var certificate: x509.Der = .{};
    try issue(&certificate, relay.credential.?.key, now, .none);
    try put_file(tmp.dir, agent_records.file_relay_certificate, certificate.slice());
    try relay.run();
    var sent: [fuzz_bytes_max]u8 = undefined;
    random.bytes(&sent);
    const length = random.intRangeAtMost(usize, 1, sent.len);
    const fd = try relay_module.dial(relay.port);
    defer _ = linux.close(fd);
    // A small receive buffer and pauses in reading push back on the relay, so its writes to the
    // job come up short and it stops reading upstream meanwhile. (`pending` stays empty here: a
    // lane reads only into an empty buffer of `relay_buffer_bytes`, which holds any record, so
    // bytes are kept back only at the byte bound, which the relay's own tests cover.)
    const small: i32 = 1;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVBUF, std.mem.asBytes(&small), 4);
    var got: [fuzz_bytes_max]u8 = undefined;
    var written: usize = 0;
    var read: usize = 0;
    const end = end_in(testing.io);
    while (read < length) {
        if (peer_stream.boot_ms(testing.io) > end) return error.Timeout;
        if (written < length) {
            const chunk = random.intRangeAtMost(usize, 1, @min(length - written, 3000));
            const flags = linux.MSG.NOSIGNAL | linux.MSG.DONTWAIT;
            const moved = linux.sendto(fd, sent[written..].ptr, chunk, flags, null, 0);
            switch (linux.errno(moved)) {
                .SUCCESS => written += moved,
                .AGAIN => {},
                else => return error.WriteFailed,
            }
        }
        if (random.uintLessThan(u8, 4) == 0) {
            try testing.io.sleep(.fromMilliseconds(random.uintLessThan(u32, 4)), .awake);
            continue;
        }
        const want = random.intRangeAtMost(usize, 1, 700);
        const count = receive(fd, got[read..][0..@min(want, got.len - read)], 20) orelse continue;
        if (count == 0) return error.EndedEarly;
        read += count;
    }
    if (!std.mem.eql(u8, sent[0..length], got[0..length])) return error.WrongBytes;
}

test "fuzz: the copy loop over TLS records split and fragmented at random moves every byte" {
    // Goal: the TLS side of the copy loop (a record half here, several records per read, short
    // writes toward the job) loses, repeats and reorders nothing. About 2 s an iteration;
    // `ZCUBE_FUZZ_ITERATIONS` runs more (fuzz_seeds.zig). Method:
    // the real relay and `tls_conn` against the scripted upstream on loopback; random stream
    // lengths, chunks and short reads; records of random sizes in random pieces with pauses.
    try seeds.run("relay tls copy fuzz", 4, tls_copy_once);
}
