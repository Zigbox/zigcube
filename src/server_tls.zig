//! The server's side of one TLS 1.3 connection (B7 slice 3, docs/mtls.md, "The API over TLS"):
//! the shell around the pure state machine of `tls_server.zig`. It runs the handshake over the
//! connection's socket reader and writer, then offers a plaintext `std.Io.Reader` and
//! `std.Io.Writer` that `std.http.Server` reads requests from and writes responses to.
//!
//! The socket's reads and writes block. What bounds them is the server's watchdog (one deadline
//! per connection state, `server_http.zig`), which shuts the socket down: the read or write then
//! fails, and so does the connection. The handshake has its state of its own, bounded by
//! `tls_handshake_timeout_ms`.
//!
//! A failure leaves its one coded diagnostic in `diag`; the plaintext reader and writer then say
//! `ReadFailed` or `WriteFailed`, as `std.http.Server` expects.

const std = @import("std");
const assert = std.debug.assert;
const api_scope = @import("api_scope.zig");
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const peer_ca = @import("peer_ca.zig");
const peer_stream = @import("peer_stream.zig");
const p256 = @import("x509_p256.zig");
const server_browser_ca = @import("server_browser_ca.zig");
const schedule = @import("tls_schedule.zig");
const secure_random = @import("secure_random.zig");
const tls_server = @import("tls_server.zig");
const x509 = @import("x509.zig");
const x509_identity = @import("x509_identity.zig");

const Diag = diag_mod.Diag;
const Ed25519 = std.crypto.sign.Ed25519;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

const plaintext_max: u32 = constants.tls_record_plaintext_bytes_max;
const sealed_max: usize = tls_server.Server.application_bytes_max(plaintext_max);

pub const Error = error{ Refused, Closed };

const Phase = enum { handshake, open, peer_closed, broken };

/// What every connection of the TLS listener shares: the CA, and the server's certificate and key,
/// made at start and made again when half the certificate's life is gone. Each connection copies
/// the certificate and the key it starts with, so a renewal never changes a handshake under way.
pub const Setup = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    ca: *const peer_ca.Ca,
    dns_name: []const u8,
    key_pair: Ed25519.KeyPair,
    certificate: x509.Der,
    not_after_ms: u64,
    cluster_buffer: [peer_ca.cluster_bytes]u8,
    cluster_length: u8,
    /// The browser path (B7 slice 6): the browser CA's key, and the P-256 key and certificate a
    /// client that does not offer Ed25519 gets, renewed with the Ed25519 pair. Null in tests
    /// that run without it.
    browser: ?BrowserIdentity,

    /// What the browser path needs from the caller: the browser CA's key and the extra names
    /// (`--tls-san`), both outliving the setup.
    pub const Browser = struct {
        ca_key: p256.KeyPair,
        sans: []const p256.San,
    };

    const BrowserIdentity = struct {
        ca_key: p256.KeyPair,
        sans: []const p256.San,
        key_pair: p256.KeyPair,
        certificate: p256.Der,
    };

    /// `ca`, `dns_name` and `browser`'s names outlive the setup. On failure `diag` says why.
    pub fn init(
        setup: *Setup,
        io: std.Io,
        ca: *const peer_ca.Ca,
        dns_name: []const u8,
        browser: ?Browser,
        diag: *Diag,
    ) Error!void {
        assert(dns_name.len > 0);
        setup.* = .{
            .io = io,
            .ca = ca,
            .dns_name = dns_name,
            .key_pair = undefined,
            .certificate = undefined,
            .not_after_ms = 0,
            .cluster_buffer = undefined,
            .cluster_length = 0,
            .browser = if (browser) |given| .{
                .ca_key = given.ca_key,
                .sans = given.sans,
                .key_pair = undefined,
                .certificate = undefined,
            } else null,
        };
        setup.cluster_length = @intCast(ca.cluster(&setup.cluster_buffer).len);
        try setup.renew(diag);
    }

    pub fn deinit(setup: *Setup) void {
        std.crypto.secureZero(u8, std.mem.asBytes(&setup.key_pair));
        if (setup.browser) |*browser| std.crypto.secureZero(u8, std.mem.asBytes(browser));
    }

    /// A new key and a certificate for it, valid `x509_leaf_ttl_ms_max` from now.
    fn renew(setup: *Setup, diag: *Diag) Error!void {
        var seed: [Ed25519.KeyPair.seed_length]u8 = undefined;
        defer std.crypto.secureZero(u8, &seed);
        secure_random.fill(setup.io, &seed, diag, "the API server's key") catch
            return error.Refused;
        const key_pair = Ed25519.KeyPair.generateDeterministic(seed) catch unreachable; // Any
        // seed makes a key pair: only the identity element fails, and a seed never hashes to it.
        const now_ms = setup.ca.wall.now_ms();
        setup.ca.issue_server_certificate(&setup.certificate, &.{
            .dns_name = setup.dns_name,
            .subject_key = key_pair.public_key.toBytes(),
            .ttl_ms = constants.x509_leaf_ttl_ms_max,
        }) catch |err| {
            diag.raise(peer_ca.code_of(err));
            diag.cause("the API server's certificate for {s}: {s}", .{
                setup.dns_name, peer_ca.reason(err),
            });
            return error.Refused;
        };
        if (setup.browser) |*browser| try setup.renew_browser(browser, diag);
        setup.key_pair = key_pair;
        setup.not_after_ms = now_ms + constants.x509_leaf_ttl_ms_max;
    }

    /// A new P-256 key and its certificate from the browser CA, for the same names and ttl.
    fn renew_browser(setup: *Setup, browser: *BrowserIdentity, diag: *Diag) Error!void {
        var seed: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &seed);
        const key_pair = server_browser_ca.make_key(setup.io, &seed, diag) catch
            return error.Refused;
        var certificate: p256.Der = .{};
        server_browser_ca.issue_server(&certificate, setup.ca, browser.ca_key, .{
            .dns_name = setup.dns_name,
            .sans = browser.sans,
        }, key_pair, constants.x509_leaf_ttl_ms_max) catch |err| {
            diag.raise(.E0106);
            diag.cause("the API server's browser certificate for {s}: {s}", .{
                setup.dns_name, @errorName(err),
            });
            diag.fix(.{ .sentence = "check --tls-name and each --tls-san" });
            return error.Refused;
        };
        browser.key_pair = key_pair;
        browser.certificate = certificate;
    }

    /// Starts `conn`'s server with the current certificate, renewing it first when half its
    /// life is gone. A renewal that fails keeps the old certificate while it lasts.
    fn start(setup: *Setup, conn: *Conn, diag: *Diag) Error!void {
        var config: tls_server.Config = .{
            .anchor = setup.ca.public(),
            .now_ms = peer_stream.wall_ms(setup.io),
            .random = undefined,
            .secret = undefined,
            .identity = undefined,
            .client_kinds = .initMany(&.{ .node, .client }),
        };
        defer std.crypto.secureZero(u8, &config.secret);
        inline for (.{ &config.random, &config.secret }) |field| {
            secure_random.fill(setup.io, field, diag, "the TLS handshake secrets") catch
                return error.Refused;
        }
        setup.mutex.lockUncancelable(setup.io);
        defer setup.mutex.unlock(setup.io);
        const half_life = constants.x509_leaf_ttl_ms_max / 2;
        if (config.now_ms +| half_life >= setup.not_after_ms) {
            var ignored: Diag = undefined;
            ignored.reset();
            setup.renew(&ignored) catch {}; // The old certificate serves until it expires.
        }
        conn.key_pair = setup.key_pair;
        const chain = [_][]const u8{setup.certificate.slice()};
        config.identity = .{
            .certificates = &chain,
            .signer = tls_server.key_pair_signer(&conn.key_pair),
        };
        var browser_chain: [1][]const u8 = undefined;
        if (setup.browser) |*browser| {
            conn.browser_key = browser.key_pair;
            browser_chain[0] = browser.certificate.slice();
            config.browser = .{
                .anchor = p256.point_of(browser.ca_key),
                .certificates = &browser_chain,
                .key = &conn.browser_key,
            };
        }
        conn.server.init(&config);
    }

    /// The caller the handshake authenticated, or null (with ZC-E0819 raised) when its name is in
    /// the CA's `revoked` file or its SPIFFE ID is not of this cluster. The names point into
    /// `conn`.
    pub fn caller(setup: *const Setup, conn: *const Conn, diag: *Diag) ?api_scope.Caller {
        const peer = conn.peer();
        const spiffe = x509_identity.spiffe_parse(peer.name) catch return refuse(diag, peer);
        const cluster = setup.cluster_buffer[0..setup.cluster_length];
        if (!std.mem.eql(u8, spiffe.cluster, cluster)) return refuse(diag, peer);
        const revoked_kind: peer_ca.Revoked.Kind = switch (peer.kind) {
            .node => .node,
            .client => .client,
            else => unreachable, // The server takes these two kinds only.
        };
        if (setup.ca.revoked.contains(revoked_kind, spiffe.name)) return refuse(diag, peer);
        switch (peer.kind) {
            .node => {
                if (spiffe.path != .node) return refuse(diag, peer);
                return .{ .node = spiffe.name };
            },
            .client => {
                if (spiffe.path != .client) return refuse(diag, peer);
                const scope = peer.scope orelse return refuse(diag, peer);
                return .{ .client = .{ .name = spiffe.name, .scope = scope } };
            },
            else => unreachable, // The server takes these two kinds only.
        }
    }

    /// ZC-E0819, with the fix for the certificate's kind: a node's comes from `issue-node`, a
    /// client's from `issue-client`.
    fn refuse(diag: *Diag, peer: tls_server.Peer) ?api_scope.Caller {
        diag.raise(.E0819);
        diag.cause("the client certificate {s} is revoked or not of this cluster", .{peer.name});
        switch (peer.kind) {
            .node => diag.fix(.{
                .sentence = "issue the node a certificate from this server's CA, under a name" ++
                    " not in the revoked file",
                .command = "zcube-server ca issue-node NAME",
            }),
            else => diag.fix(.{
                .sentence = "issue the client a certificate from this server's CA, under a name" ++
                    " not in the revoked file",
                .command = "zcube-server ca issue-client NAME --scope jobs|admin",
            }),
        }
        return null;
    }
};

/// Large (the state machine holds its record buffers), so it is set up in place and not moved:
/// the plaintext reader and writer find it by their field.
pub const Conn = struct {
    server: tls_server.Server,
    /// The server key this connection signs its handshake with: a copy, so a renewal in
    /// `Setup` never changes it mid-handshake.
    key_pair: Ed25519.KeyPair,
    /// The browser path's key, copied the same way (unused without a browser identity).
    browser_key: p256.KeyPair,
    /// The socket's own reader and writer: ciphertext.
    raw_reader: *Reader,
    raw_writer: *Writer,
    diag: *Diag,
    phase: Phase,
    /// Application data of the last record that the reader has not handed on.
    pending: []const u8,
    /// Bytes read for the server's next step: at most one record.
    stage: [schedule.sealed_bytes_max]u8,
    sealed: [sealed_max]u8,
    /// The plaintext side. The reader's buffer is the caller's; the writer's is one record.
    reader: Reader,
    writer: Writer,
    plain: [plaintext_max]u8,

    /// Starts the server from `setup` and runs the handshake. On failure `diag` holds why, and
    /// `deinit` is all that remains.
    pub fn open(
        conn: *Conn,
        setup: *Setup,
        raw_reader: *Reader,
        raw_writer: *Writer,
        read_buffer: []u8,
        diag: *Diag,
    ) Error!void {
        assert(read_buffer.len > 0);
        conn.raw_reader = raw_reader;
        conn.raw_writer = raw_writer;
        conn.diag = diag;
        conn.phase = .handshake;
        conn.pending = &.{};
        conn.reader = .{ .vtable = &reader_vtable, .buffer = read_buffer, .seek = 0, .end = 0 };
        conn.writer = .{ .vtable = &writer_vtable, .buffer = &conn.plain, .end = 0 };
        conn.phase = .broken;
        try setup.start(conn, diag);
        conn.phase = .handshake;
        while (!conn.server.is_connected()) {
            const result = conn.step() catch |err| {
                conn.phase = .broken;
                return err;
            };
            switch (result.event) {
                .none, .connected => {},
                .data, .closed => unreachable, // The server emits these only once connected.
            }
        }
        conn.phase = .open;
    }

    /// Wipes every secret. The socket stays the caller's.
    pub fn deinit(conn: *Conn) void {
        std.crypto.secureZero(u8, std.mem.asBytes(&conn.server));
        std.crypto.secureZero(u8, std.mem.asBytes(&conn.key_pair));
        std.crypto.secureZero(u8, std.mem.asBytes(&conn.browser_key));
        std.crypto.secureZero(u8, &conn.plain);
        std.crypto.secureZero(u8, &conn.sealed);
        std.crypto.secureZero(u8, &conn.stage);
        conn.pending = &.{};
        conn.phase = .broken;
    }

    /// The client the handshake authenticated.
    pub fn peer(conn: *const Conn) tls_server.Peer {
        assert(conn.phase == .open);
        return conn.server.peer().?; // The server requires a client certificate.
    }

    /// Sends close_notify if the connection is still open; a client that is gone costs nothing.
    pub fn close(conn: *Conn) void {
        if (conn.phase != .open) return;
        conn.writer.flush() catch return;
        conn.server.close_notify();
        conn.phase = .peer_closed;
        conn.send_output() catch {}; // A courtesy: the client need not hear it.
    }

    /// Reads at most one record's worth for the server and sends what it answers.
    fn step(conn: *Conn) Error!tls_server.Step {
        const want = conn.server.wants();
        assert(want > 0);
        const got = conn.raw_reader.readSliceShort(conn.stage[0..want]) catch 0;
        if (got == 0) return conn.ended();
        const step_result = conn.server.receive(conn.stage[0..got], conn.diag) catch |err| {
            conn.refused();
            return err;
        };
        assert(step_result.consumed == got); // Asked for at most `wants()`.
        try conn.send_output();
        return step_result;
    }

    fn send_output(conn: *Conn) Error!void {
        const bytes = conn.server.output();
        if (bytes.len == 0) return;
        defer conn.server.drain();
        conn.push(bytes) catch return conn.ended();
    }

    fn push(conn: *Conn, bytes: []const u8) Writer.Error!void {
        try conn.raw_writer.writeAll(bytes);
        try conn.raw_writer.flush();
    }

    /// The transport ended or failed: the server says what that means here.
    fn ended(conn: *Conn) Error {
        conn.phase = .broken;
        conn.server.end_of_input(conn.diag) catch |err| switch (err) {
            error.Closed => return error.Closed,
            error.Refused => return error.Refused,
        };
        return error.Closed; // After close_notify the end is not an error.
    }

    /// The server refused (its diagnostic is raised, an alert may wait): send the alert if the
    /// socket takes it, and end the connection.
    fn refused(conn: *Conn) void {
        conn.phase = .broken;
        const alert = conn.server.output();
        if (alert.len > 0) conn.push(alert) catch {}; // A courtesy, never worth more.
        conn.server.drain();
    }

    // ---- The plaintext reader -------------------------------------------------------------

    const reader_vtable: Reader.VTable = .{ .stream = stream };

    fn stream(r: *Reader, w: *Writer, limit: std.Io.Limit) Reader.StreamError!usize {
        const conn: *Conn = @alignCast(@fieldParentPtr("reader", r));
        if (conn.pending.len == 0) try conn.next_data();
        const count = try w.write(limit.sliceConst(conn.pending));
        conn.pending = conn.pending[count..];
        return count;
    }

    /// Reads records until one carries application data.
    fn next_data(conn: *Conn) Reader.StreamError!void {
        assert(conn.pending.len == 0);
        while (true) {
            switch (conn.phase) {
                .open => {},
                .peer_closed => return error.EndOfStream,
                .broken => return error.ReadFailed,
                .handshake => unreachable,
            }
            const result = conn.step() catch |err| switch (err) {
                error.Closed => {
                    conn.phase = .peer_closed;
                    return error.EndOfStream;
                },
                error.Refused => return error.ReadFailed,
            };
            switch (result.event) {
                .none => {},
                .data => |data| if (data.len > 0) {
                    conn.pending = data;
                    return;
                },
                .closed => {
                    conn.phase = .peer_closed;
                    return error.EndOfStream;
                },
                .connected => unreachable, // Once.
            }
        }
    }

    // ---- The plaintext writer -------------------------------------------------------------

    const writer_vtable: Writer.VTable = .{ .drain = drain };

    /// Seals what is buffered as one record and sends it, then copies as much of `data` (the
    /// last element `splat` times) into the emptied buffer as fits, and returns that count.
    /// Taking from `data` is what lets a write larger than one record make progress: a drain
    /// that returned 0 with the buffer empty would be called again for ever.
    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        assert(data.len > 0);
        const conn: *Conn = @alignCast(@fieldParentPtr("writer", w));
        if (conn.phase != .open) return error.WriteFailed;
        if (w.end > 0) try conn.seal_buffered(w);
        assert(w.end == 0);
        return copy_into(w, data, splat);
    }

    fn seal_buffered(conn: *Conn, w: *Writer) Writer.Error!void {
        assert(w.end > 0);
        const plain = w.buffer[0..w.end];
        w.end = 0;
        const sealed = conn.server.seal_application(plain, &conn.sealed, conn.diag) catch {
            conn.refused();
            return error.WriteFailed;
        };
        conn.push(sealed) catch {
            conn.phase = .broken;
            return error.WriteFailed;
        };
    }

    /// Copies the bytes of `data`, its last element repeated `splat` times, into `w`'s buffer
    /// until it is full. Returns the bytes taken.
    fn copy_into(w: *Writer, data: []const []const u8, splat: usize) usize {
        const head = data[0 .. data.len - 1];
        const pattern = data[data.len - 1];
        var taken: usize = 0;
        for (head) |bytes| {
            const room = w.buffer.len - w.end;
            const count = @min(room, bytes.len);
            @memcpy(w.buffer[w.end..][0..count], bytes[0..count]);
            w.end += count;
            taken += count;
            if (count < bytes.len) return taken;
        }
        if (pattern.len == 0) return taken;
        var repeat: usize = 0;
        while (repeat < splat) : (repeat += 1) {
            const room = w.buffer.len - w.end;
            const count = @min(room, pattern.len);
            @memcpy(w.buffer[w.end..][0..count], pattern[0..count]);
            w.end += count;
            taken += count;
            if (count < pattern.len) return taken;
        }
        return taken;
    }
};
