//! A TLS 1.3 client connection over a socket (docs/briefs/mtls-client.md, slice 6): the shell
//! around the pure state machine in `tls_client.zig`. It owns what the core must not touch: the
//! descriptor, `poll`, the wall clock and the system's randomness. It does not own the descriptor
//! itself; the caller closes it.
//!
//! Every wait is a `poll` against an absolute deadline on CLOCK_BOOTTIME, and every read and
//! write is `MSG.DONTWAIT`, so a peer that stops sending or reading ends in a timeout and never
//! holds a thread (a socket timeout would make the standard library's reader panic, ZC-B0001).
//! The handshake has one deadline of its own, `tls_handshake_timeout_ms`, from the first byte
//! sent: a server that answers a byte a second still ends there.
//!
//! The reader is a stream. The client takes at most `wants()` bytes per step, so the connection
//! never reads ahead of a record, and a record is handed over as soon as it is whole: a server-sent
//! event is readable the moment its record has arrived (docs/briefs/mtls-client.md, "SSE").
//! `write` seals and sends everything it is given before it returns.
//!
//! What a call returns:
//!   - `Refused`: the connection failed and `diag` holds the one coded diagnostic.
//!   - `Closed`: the connection is over, or was ended by an earlier failure; nothing is raised.
//!   - `Timeout`: the caller's deadline passed. For `read` the connection is intact and the call
//!     may be repeated. For `write` and `flush` the record may be half sent, so the connection is
//!     over and every later call answers `Closed`.
//!   A `read` that must send (the answer to a KeyUpdate) and cannot in time does not return
//!   `Timeout`: its keys have moved on, so the connection is over and the call says `Refused`
//!   with ZC-E0816 in `diag`.
//!
//! The cuts, recorded in docs/decisions/2026-11-05-tls-conn.md: no new diagnostic (a transport
//! that breaks is ZC-E0816, a handshake that runs out of time is ZC-E0816 too); `close` does not
//! wait for the server's close_notify; after the server's close_notify nothing more is written.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const peer_stream = @import("peer_stream.zig");
const schedule = @import("tls_schedule.zig");
const tls_client = @import("tls_client.zig");

const Diag = diag_mod.Diag;
const linux = std.os.linux;

pub const Error = error{ Refused, Closed, Timeout };

/// What `pull` and `push` can say; the caller turns it into an `Error` and, when it must, a
/// diagnostic.
const Wire = error{ Timeout, Ended };

pub const Options = struct {
    io: std.Io,
    /// A connected socket. Any mode: no call here blocks.
    fd: std.posix.fd_t,
    /// The pinned CA public key.
    anchor: [32]u8,
    /// The DNS name connected to.
    server_name: []const u8,
    /// The workload identity, if the server may ask for it. Its signer outlives the connection.
    client_auth: tls_client.ClientAuth = .none,
    handshake_timeout_ms: u32 = constants.tls_handshake_timeout_ms,
};

/// The deadline for the answer to a KeyUpdate: the read's, but never less than
/// `tls_alert_flush_ms` from now, so the answer gets at least one send attempt.
pub fn reply_end_ms(now_ms: u64, end_ms: u64) u64 {
    return @max(end_ms, now_ms + constants.tls_alert_flush_ms);
}

const plaintext_max: u32 = constants.tls_record_plaintext_bytes_max;
const sealed_max: u32 = tls_client.Client.application_bytes_max(plaintext_max);

const Phase = enum {
    /// `open` has not returned.
    handshake,
    open,
    /// The server sent close_notify: reads say end of stream, writes are refused.
    peer_closed,
    /// This side sent close_notify.
    shut,
    /// Failed or timed out mid-record: nothing more is read or written.
    broken,
};

/// Large (the client holds its record buffers), so it is set up in place and not moved: an
/// event's data points into the client until the next read.
pub const Conn = struct {
    io: std.Io,
    fd: std.posix.fd_t,
    client: tls_client.Client,
    phase: Phase,
    /// Application data of the last record that the caller's buffer did not take.
    pending: []const u8,
    /// Written, not yet sealed.
    plain: [plaintext_max]u8,
    plain_length: u32,
    sealed: [sealed_max]u8,
    /// Bytes read for the client's next step; at most one record.
    stage: [schedule.sealed_bytes_max]u8,
    /// The last errno that ended the transport, for the diagnostic.
    errno: linux.E,

    /// Runs the handshake to the end, or fails with a diagnostic. On failure the connection is
    /// over and `deinit` is all that remains.
    pub fn open(conn: *Conn, options: *const Options, diag: *Diag) Error!void {
        assert(options.handshake_timeout_ms > 0);
        assert(options.server_name.len > 0);
        const io = options.io;
        conn.io = io;
        conn.fd = options.fd;
        conn.phase = .handshake;
        conn.pending = &.{};
        conn.plain_length = 0;
        conn.errno = .SUCCESS;
        var config: tls_client.Config = .{
            .anchor = options.anchor,
            .server_name = options.server_name,
            .now_ms = peer_stream.wall_ms(io),
            .random = peer_stream.random_seed(io),
            .session_id = peer_stream.random_seed(io),
            .secret = peer_stream.random_seed(io),
            .client_auth = options.client_auth,
        };
        conn.client.init(&config);
        std.crypto.secureZero(u8, &config.secret);
        const end_ms = peer_stream.boot_ms(io) + options.handshake_timeout_ms;
        conn.client.start();
        conn.handshake(end_ms, options.handshake_timeout_ms, diag) catch |err| {
            conn.phase = .broken;
            return err;
        };
        assert(conn.client.is_connected());
        conn.phase = .open;
    }

    /// Wipes every secret. The descriptor stays the caller's.
    pub fn deinit(conn: *Conn) void {
        std.crypto.secureZero(u8, std.mem.asBytes(&conn.client));
        std.crypto.secureZero(u8, &conn.plain);
        std.crypto.secureZero(u8, &conn.sealed);
        std.crypto.secureZero(u8, &conn.stage);
        conn.pending = &.{};
        conn.phase = .broken;
    }

    fn handshake(conn: *Conn, end_ms: u64, timeout_ms: u32, diag: *Diag) Error!void {
        assert(conn.phase == .handshake);
        try conn.send_output(end_ms, diag, .{ .handshake = timeout_ms });
        while (!conn.client.is_connected()) {
            const want = conn.client.wants();
            assert(want > 0);
            const got = conn.pull(conn.stage[0..want], end_ms) catch |err|
                return conn.wire_failure(err, diag, .{ .handshake = timeout_ms });
            const step = conn.client.receive(conn.stage[0..got], diag) catch |err|
                return conn.refused(err);
            assert(step.consumed == got); // Asked for at most `wants()`.
            try conn.send_output(end_ms, diag, .{ .handshake = timeout_ms });
            switch (step.event) {
                .none, .connected => {},
                // The client emits these only once connected.
                .data, .closed => unreachable,
            }
        }
    }

    // ---- Reading ------------------------------------------------------------------------------

    /// Reads application data into `out` and returns how many bytes: at least one, and never
    /// more than one record. 0 is the server's close_notify, repeated for as long as asked. A
    /// `Timeout` leaves the connection as it was: nothing was consumed, and the call may be
    /// repeated. A send made on the read's behalf that runs out of time is `Refused`, not
    /// `Timeout`: the connection is over.
    pub fn read(conn: *Conn, out: []u8, end_ms: u64, diag: *Diag) Error!usize {
        assert(out.len > 0);
        switch (conn.phase) {
            .open => {},
            .peer_closed => return 0,
            .shut, .broken => return error.Closed,
            .handshake => unreachable, // `open` has not returned.
        }
        if (conn.pending.len > 0) return conn.take_pending(out);
        while (true) {
            const want = conn.client.wants();
            assert(want > 0); // An open connection reads on.
            const got = conn.pull(conn.stage[0..want], end_ms) catch |err|
                return conn.wire_failure(err, diag, .read);
            const step = conn.client.receive(conn.stage[0..got], diag) catch |err|
                return conn.refused(err);
            assert(step.consumed == got);
            if (step.event == .closed) {
                // The reply to the server's close_notify is a courtesy, and the stream has ended
                // either way: a failure to send it changes nothing, and `phase` must say so, or
                // a repeated read would ask a closed client for more input.
                conn.phase = .peer_closed;
                conn.say_goodbye(end_ms);
                return 0;
            }
            // The answer to a KeyUpdate: the write keys have moved on, so a record that is not
            // whole on the wire cannot be taken back. It has a budget of its own, so a read
            // deadline that ticks by now does not kill a healthy connection, and a timeout
            // here ends the connection.
            try conn.send_output(reply_end_ms(peer_stream.boot_ms(conn.io), end_ms), diag, .reply);
            switch (step.event) {
                .none => {},
                .data => |data| if (data.len > 0) {
                    conn.pending = data;
                    return conn.take_pending(out);
                },
                .closed => unreachable, // Handled above.
                .connected => unreachable, // Once.
            }
        }
    }

    fn take_pending(conn: *Conn, out: []u8) usize {
        assert(conn.pending.len > 0);
        const count = @min(out.len, conn.pending.len);
        @memcpy(out[0..count], conn.pending[0..count]);
        conn.pending = conn.pending[count..];
        assert(count > 0);
        return count;
    }

    // ---- Writing ------------------------------------------------------------------------------

    /// Seals and sends `bytes`, one record per `plaintext_max` bytes; the call ends with nothing
    /// queued. `flush` is for a caller that wrote nothing since the last call (and so a no-op).
    pub fn write(conn: *Conn, bytes: []const u8, end_ms: u64, diag: *Diag) Error!void {
        try conn.writable();
        var rest = bytes;
        while (rest.len > 0) {
            const space = plaintext_max - conn.plain_length;
            assert(space > 0); // A full record is sent before the loop goes on.
            const count: u32 = @intCast(@min(rest.len, space));
            @memcpy(conn.plain[conn.plain_length..][0..count], rest[0..count]);
            conn.plain_length += count;
            rest = rest[count..];
            if (conn.plain_length == plaintext_max) try conn.send_record(end_ms, diag);
        }
        try conn.flush(end_ms, diag);
        assert(conn.plain_length == 0);
    }

    /// Seals and sends what `write` has queued.
    pub fn flush(conn: *Conn, end_ms: u64, diag: *Diag) Error!void {
        try conn.writable();
        if (conn.plain_length > 0) try conn.send_record(end_ms, diag);
        assert(conn.plain_length == 0);
    }

    /// Flushes, then sends close_notify and ends the connection. It does not wait for the
    /// server's: the client has stopped reading by then, and a slot is not worth holding for a
    /// goodbye. A peer that is already gone costs nothing: that failure is dropped. After a peer
    /// close_notify, or a failed seal, nothing queued is sent: both wipe `plain` (see `send_record`).
    pub fn close(conn: *Conn, end_ms: u64, diag: *Diag) Error!void {
        switch (conn.phase) {
            .open => {},
            .peer_closed, .shut, .broken => {
                // `write` sends every byte before it returns, and `send_record` empties `plain`
                // even when the seal fails, so nothing is queued here.
                assert(conn.plain_length == 0);
                return;
            },
            .handshake => unreachable,
        }
        try conn.flush(end_ms, diag);
        conn.client.close_notify();
        conn.phase = .shut;
        // Not `send_output`: a failure here must not raise a diagnostic for a close that worked.
        conn.say_goodbye(end_ms);
    }

    /// Sends the client's pending close_notify (the reply to the peer's, or our own) if it can
    /// be done within `tls_alert_flush_ms` and the caller's deadline. The peer need not hear it.
    fn say_goodbye(conn: *Conn, end_ms: u64) void {
        const limit = peer_stream.boot_ms(conn.io) + constants.tls_alert_flush_ms;
        conn.push(conn.client.output(), @min(end_ms, limit)) catch {};
        conn.client.drain();
    }

    fn writable(conn: *const Conn) Error!void {
        switch (conn.phase) {
            .open => {},
            .peer_closed, .shut, .broken => return error.Closed,
            .handshake => unreachable,
        }
    }

    fn send_record(conn: *Conn, end_ms: u64, diag: *Diag) Error!void {
        assert(conn.plain_length > 0);
        assert(conn.phase == .open);
        const plain = conn.plain[0..conn.plain_length];
        const sealed = conn.client.seal_application(plain, &conn.sealed, diag) catch |err| {
            // The bytes can never be sent now: drop them, so a `close` after the refusal finds
            // nothing queued.
            std.crypto.secureZero(u8, plain);
            conn.plain_length = 0;
            return conn.refused(err);
        };
        conn.plain_length = 0;
        conn.push(sealed, end_ms) catch |err| return conn.wire_failure(err, diag, .write);
    }

    // ---- Failures -----------------------------------------------------------------------------

    /// `reply` is a send made for a read (a KeyUpdate answer): fatal on timeout, like `write`.
    const Where = union(enum) { handshake: u32, read, write, reply };

    /// The client refused (its diagnostic is raised, an alert may wait): say goodbye if it can
    /// be done at once, and end the connection.
    fn refused(conn: *Conn, err: tls_client.Error) Error {
        conn.phase = .broken;
        switch (err) {
            error.Closed => return error.Closed,
            error.Refused => {},
        }
        const end_ms = peer_stream.boot_ms(conn.io) + constants.tls_alert_flush_ms;
        const alert = conn.client.output();
        // A courtesy to the server, never worth waiting for.
        if (alert.len > 0) conn.push(alert, end_ms) catch {};
        conn.client.drain();
        return error.Refused;
    }

    /// The transport failed or ran out of time. A read that merely timed out changes nothing.
    fn wire_failure(conn: *Conn, err: Wire, diag: *Diag, where: Where) Error {
        switch (err) {
            error.Timeout => switch (where) {
                .read => return error.Timeout,
                .write => {
                    conn.phase = .broken;
                    return error.Timeout;
                },
                .reply => return conn.reply_timeout(diag),
                .handshake => |timeout_ms| return conn.handshake_timeout(diag, timeout_ms),
            },
            error.Ended => {},
        }
        conn.phase = .broken;
        if (conn.client.end_of_input(diag)) |_| {
            return error.Closed; // The client had already closed.
        } else |client_err| switch (client_err) {
            error.Closed => return error.Closed,
            error.Refused => {},
        }
        if (conn.errno != .SUCCESS) diag.context("os", "{s}", .{@tagName(conn.errno)});
        return error.Refused;
    }

    /// The answer to the server's KeyUpdate could not be sent in time. The write keys have
    /// moved on, so the connection is over; the caller learns it here, not at the next call.
    fn reply_timeout(conn: *Conn, diag: *Diag) Error {
        conn.phase = .broken;
        diag.raise(.E0816);
        diag.cause("the answer to the server's KeyUpdate was not sent within {d} ms", .{
            constants.tls_alert_flush_ms,
        });
        var buffer: [constants.tls_server_name_bytes_max + 160]u8 = undefined;
        const name = conn.client.name[0..conn.client.name_length];
        const sentence = std.fmt.bufPrint(
            &buffer,
            "Check that the server at {s} reads promptly, then reconnect.",
            .{name},
        ) catch unreachable; // The buffer holds the longest name and the sentence.
        diag.fix(.{ .sentence = sentence });
        return error.Refused;
    }

    fn handshake_timeout(conn: *Conn, diag: *Diag, timeout_ms: u32) Error {
        conn.phase = .broken;
        diag.raise(.E0816);
        diag.cause("the TLS handshake did not finish within {d} ms", .{timeout_ms});
        var buffer: [constants.tls_server_name_bytes_max + 160]u8 = undefined;
        const name = conn.client.name[0..conn.client.name_length];
        const sentence = std.fmt.bufPrint(
            &buffer,
            "Check that the server at {s} is reachable and answers promptly, then reconnect.",
            .{name},
        ) catch unreachable; // The buffer holds the longest name and the sentence.
        diag.fix(.{ .sentence = sentence });
        return error.Refused;
    }

    // ---- The socket ---------------------------------------------------------------------------

    /// Sends what the client has ready and tells it so.
    fn send_output(conn: *Conn, end_ms: u64, diag: *Diag, where: Where) Error!void {
        const bytes = conn.client.output();
        if (bytes.len == 0) return;
        defer conn.client.drain();
        conn.push(bytes, end_ms) catch |err| return conn.wire_failure(err, diag, where);
    }

    /// Reads between 1 and `out.len` bytes by `end_ms`.
    fn pull(conn: *Conn, out: []u8, end_ms: u64) Wire!u32 {
        assert(out.len > 0);
        while (true) {
            peer_stream.wait_ready(conn.io, conn.fd, std.posix.POLL.IN, end_ms) catch |err| {
                if (err == error.Timeout) return error.Timeout;
                return error.Ended;
            };
            // MSG.DONTWAIT: the poll's deadline is the only wait.
            const got = linux.recvfrom(conn.fd, out.ptr, out.len, linux.MSG.DONTWAIT, null, null);
            switch (linux.errno(got)) {
                .SUCCESS => {
                    if (got == 0) return error.Ended;
                    assert(got <= out.len);
                    return @intCast(got);
                },
                .AGAIN, .INTR => {},
                else => |code| {
                    conn.errno = code;
                    return error.Ended;
                },
            }
        }
    }

    fn push(conn: *Conn, bytes: []const u8, end_ms: u64) Wire!void {
        const flags = linux.MSG.DONTWAIT | linux.MSG.NOSIGNAL;
        var at: usize = 0;
        while (at < bytes.len) {
            peer_stream.wait_ready(conn.io, conn.fd, std.posix.POLL.OUT, end_ms) catch |err| {
                if (err == error.Timeout) return error.Timeout;
                return error.Ended;
            };
            const wrote = linux.sendto(conn.fd, bytes.ptr + at, bytes.len - at, flags, null, 0);
            switch (linux.errno(wrote)) {
                .SUCCESS => at += wrote,
                .AGAIN, .INTR => {},
                else => |code| {
                    conn.errno = code;
                    return error.Ended;
                },
            }
        }
    }
};
