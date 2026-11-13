//! The TLS side of a job's relay (B4 slice 2, docs/briefs/b4.md): the run's credential, which the
//! relay waits for before it dials, and the `Sys` the copy loop uses when the upstream speaks TLS.
//! Shell code (files, sockets), run inside the job's supervisor.
//!
//! The key is the supervisor's: it makes the pair, keeps it in this process's memory only, and
//! hands the relay a pointer. The agent asks the server for the certificate and writes it into
//! the container's directory as `relay.crt` (DER), or writes `relay.refused` when the server
//! said ZC-E0706. The relay's acceptor reads those files until one is there; a certificate whose
//! key is not the run's is ignored, so nothing the directory holds can change whose key signs.
//!
//! The copy loop and TLS: `Conn.read` takes one record and keeps what the caller's buffer did not
//! take (`pending`); the loop must not wait in `poll` while it holds bytes, so `buffered` says so.
//! `Conn.write` seals and sends everything before it returns; it waits at most the idle bound,
//! and `Relay.stop` shuts the socket down, which ends that wait at once. `tls_conn` has no half
//! close (its `close` sends `close_notify` and stops reading), so the job's end closes the
//! upstream connection: what the upstream sends after it is dropped
//! (docs/decisions/2026-11-13-b4-relay-tls.md).

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const peer_stream = @import("peer_stream.zig");
const tls_client = @import("tls_client.zig");
const tls_conn = @import("tls_conn.zig");
const x509 = @import("x509.zig");
const agent_records = @import("agent_records.zig");

const Diag = diag_mod.Diag;
const Ed25519 = std.crypto.sign.Ed25519;
const linux = std.os.linux;
const fd_t = linux.fd_t;

/// The upstream's server, as the relay's configuration names it: the DNS name its leaf must carry
/// and the Ed25519 key of the CA that signs it.
pub const Tls = struct {
    server_name: []const u8,
    anchor: [32]u8,
};

/// A relay entry's upstream TLS from the spec's text (`server_name`, 64 hex digits of the
/// anchor); null if either is missing or the anchor is not 64 hex digits.
pub fn tls_of(server_name: []const u8, anchor_hex: []const u8) ?Tls {
    if (server_name.len == 0) return null;
    if (anchor_hex.len != 64) return null;
    var anchor: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&anchor, anchor_hex) catch return null;
    return .{ .server_name = server_name, .anchor = anchor };
}

/// A plain-TCP upstream (B3's) is served only by a Debug build, as the server admits one only
/// from a Debug build's configuration (`server_config.relay_plain_allowed`).
pub const plain_allowed = @import("builtin").mode == .debug;

pub const State = enum(u8) { waiting, ready, refused };

/// The run's certificate and key. `state` moves once, from `waiting`, and is read by every
/// connection thread; the certificate is written before `ready` is stored and never after.
pub const Credential = struct {
    state: std.atomic.Value(State) = .init(.waiting),
    key: Ed25519.KeyPair,
    certificate: x509.Der = .{},
    chain: [1][]const u8 = undefined,

    pub fn init(key: Ed25519.KeyPair) Credential {
        return .{ .key = key };
    }

    pub fn identity(credential: *const Credential) tls_client.Identity {
        assert(credential.state.load(.acquire) == .ready);
        return .{
            .certificates = &credential.chain,
            .signer = tls_client.key_pair_signer(&credential.key),
        };
    }

    /// Looks once for `relay.crt` or `relay.refused` in `dir_fd` (the container's directory).
    /// A certificate that does not parse, or whose key is not the run's, is left where it is and
    /// not taken: the next look reads it again (the agent writes it atomically).
    pub fn poll(credential: *Credential, dir_fd: fd_t) void {
        assert(credential.state.load(.acquire) == .waiting);
        if (exists(dir_fd, agent_records.file_relay_refused)) {
            credential.state.store(.refused, .release);
            return;
        }
        var bytes: [constants.x509_cert_bytes_max]u8 = undefined;
        const length = read_file(dir_fd, agent_records.file_relay_certificate, &bytes) orelse
            return;
        credential.take(bytes[0..length]) catch return;
    }

    /// Takes `bytes` as the run's certificate if it is one for the run's key.
    pub fn take(credential: *Credential, bytes: []const u8) error{NotTheRunKey}!void {
        assert(credential.state.load(.acquire) == .waiting);
        var detail: x509.Detail = .{};
        const parsed = x509.parse_profile(bytes, .cluster, &detail) catch
            return error.NotTheRunKey;
        if (parsed.kind != .workload) return error.NotTheRunKey;
        const key = parsed.public_key.of(bytes);
        if (!std.mem.eql(u8, key, &credential.key.public_key.toBytes())) {
            return error.NotTheRunKey;
        }
        const der = &credential.certificate;
        der.start = @intCast(der.bytes.len - bytes.len);
        @memcpy(der.bytes[der.start..], bytes);
        credential.chain = .{der.slice()};
        credential.state.store(.ready, .release);
    }
};

fn exists(dir_fd: fd_t, name: [*:0]const u8) bool {
    const opened = linux.openat(dir_fd, name, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return false;
    _ = linux.close(@intCast(opened));
    return true;
}

/// The whole of a small file, or null if it is absent, unreadable or larger than `out`.
fn read_file(dir_fd: fd_t, name: [*:0]const u8, out: []u8) ?usize {
    const opened = linux.openat(dir_fd, name, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return null;
    const fd: fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    var length: usize = 0;
    while (length < out.len) {
        const got = linux.read(fd, out[length..].ptr, out.len - length);
        if (linux.errno(got) != .SUCCESS) return null;
        if (got == 0) return if (length == 0) null else length;
        length += got;
    }
    // Full: a file larger than a certificate is not one.
    var extra: [1]u8 = undefined;
    const more = linux.read(fd, &extra, 1);
    if (linux.errno(more) != .SUCCESS or more != 0) return null;
    return length;
}

/// What the TLS side of one connection did, for `relay.log`.
pub const Side = struct {
    conn: *tls_conn.Conn,
    fd: fd_t,
    io: std.Io,
    /// How long a write may wait for the upstream to take its bytes: the idle bound.
    write_ms: u32,
    diag: *Diag,
    /// The job's end came and `close_notify` went: the upstream's lane reads as ended.
    end_sent: bool = false,
};

/// The copy loop's calls (`relay.zig`'s `round`): the job's socket is plain, the upstream's is
/// the TLS connection.
pub const Sys = struct {
    pub const shutdown_wrong_end = false;

    side: *Side,

    pub fn read(sys: Sys, fd: fd_t, buffer: []u8) Moved {
        if (fd != sys.side.fd) return plain_read(fd, buffer);
        const side = sys.side;
        if (side.end_sent) return .{ .count = 0 };
        if (!buffered(side) and !readable(fd)) return .again;
        // A record may be half here: one millisecond, then `Timeout`, which keeps it whole in
        // the client for the next call.
        const end_ms = peer_stream.boot_ms(side.io) + 1;
        const got = side.conn.read(buffer, end_ms, side.diag) catch |err| return switch (err) {
            error.Timeout => .again,
            error.Refused, error.Closed, error.Canceled => .failed,
        };
        return .{ .count = got };
    }

    pub fn write(sys: Sys, fd: fd_t, bytes: []const u8) Moved {
        if (fd != sys.side.fd) return plain_write(fd, bytes);
        const side = sys.side;
        const end_ms = peer_stream.boot_ms(side.io) + side.write_ms;
        side.conn.write(bytes, end_ms, side.diag) catch return .failed;
        return .{ .count = bytes.len };
    }

    pub fn shutdown_write(sys: Sys, fd: fd_t) void {
        if (fd != sys.side.fd) {
            _ = linux.shutdown(fd, linux.SHUT.WR);
            return;
        }
        const side = sys.side;
        const end_ms = peer_stream.boot_ms(side.io) + constants.tls_alert_flush_ms;
        side.conn.close(end_ms, side.diag) catch {}; // A peer already gone costs nothing here.
        side.end_sent = true;
    }

    /// True when the TLS side holds bytes already read: `poll` would not see them.
    pub fn ready(sys: Sys) bool {
        return buffered(sys.side);
    }
};

pub const Moved = union(enum) { count: usize, again, failed };

fn buffered(side: *const Side) bool {
    return side.conn.pending.len > 0;
}

fn readable(fd: fd_t) bool {
    var fds = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
    return linux.poll(&fds, 1, 0) > 0;
}

fn plain_read(fd: fd_t, buffer: []u8) Moved {
    const got = linux.read(fd, buffer.ptr, buffer.len);
    return switch (linux.errno(got)) {
        .SUCCESS => .{ .count = got },
        .AGAIN, .INTR => .again,
        else => .failed,
    };
}

fn plain_write(fd: fd_t, bytes: []const u8) Moved {
    const sent = linux.sendto(fd, bytes.ptr, bytes.len, linux.MSG.NOSIGNAL, null, 0);
    return switch (linux.errno(sent)) {
        .SUCCESS => .{ .count = sent },
        .AGAIN, .INTR => .again,
        else => .failed,
    };
}
