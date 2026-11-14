//! The agent's check of the certificate it presents, before each new API connection (B7 slice
//! 5, docs/agent.md "Node certificates"). The agent renews its `node.crt` at half its life and
//! tries again on failure; this is what happens when that keeps failing:
//!
//! - Once 3/4 of the certificate's life has passed, one stderr line names its expiry and the
//!   last renewal error. A new certificate (a renewal) arms the line again.
//! - Once it is outside its window (x509.window: not_before - 60 s to not_after + 60 s), it is
//!   no longer presented. `--cert` and `--key`, read from their files then, take its place if
//!   they hold a node certificate for this node valid now, with one stderr note. Else the call
//!   fails with ZC-E0811, naming the expiry, the last renewal error and why `--cert` was not
//!   used; the agent's loop paces the retries as for a server it cannot reach.
//!
//! Shell code (`FileFallback` reads files); `Guard` itself reads only its clock and fallback,
//! so the tests drive it with a manual clock and a certificate in memory.

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const api_tls_client = @import("api_tls_client.zig");
const diag_mod = @import("diag.zig");
const x509 = @import("x509.zig");

const Clock = @import("clock.zig").Clock;
const Credentials = api_tls_client.Credentials;
const Diag = diag_mod.Diag;

/// Test-only fault for the teeth test: the check passes whatever the certificate's window.
pub const TestFault = enum { check };
var faults: [std.enums.values(TestFault).len]bool = @splat(false);

pub fn set_test_fault(fault: TestFault, on: bool) void {
    if (builtin.is_test) faults[@backingInt(fault)] = on;
}

fn fault_on(fault: TestFault) bool {
    return builtin.is_test and faults[@backingInt(fault)];
}

const reason_bytes_max = 160;
const line_bytes_max = 320;

/// Where `--cert` and `--key` come from when the presented certificate is no longer valid.
pub const Fallback = struct {
    context: *anyopaque,
    /// Loads them into `trial` (a copy of the credentials) and checks that they are a node
    /// certificate for this node, valid at `now_ms`, of the key beside it. Null when they are;
    /// else why not.
    load: *const fn (context: *anyopaque, trial: *Credentials, now_ms: u64) ?[]const u8,
};

pub const Guard = struct {
    io: std.Io,
    /// Wall time, Unix milliseconds: what the certificate's window is judged by.
    wall: Clock,
    fallback: ?Fallback,
    /// No stderr: the tests read `last_line`.
    silent: bool,
    /// The not_after of the certificate the 3/4 line was written for; 0 for none.
    warned_ms: u64 = 0,
    /// The not_after of the certificate the fallback note was written for; 0 for none.
    noted_ms: u64 = 0,
    renewal_error_buffer: [reason_bytes_max]u8 = undefined,
    renewal_error_length: u8 = 0,
    lines: u32 = 0,
    line_buffer: [line_bytes_max]u8 = undefined,
    line_length: u16 = 0,

    /// Records the agent's latest failed credential step (a join or renewal): its code and its
    /// last cause.
    pub fn renewal_failed(guard: *Guard, diag: *const Diag) void {
        const code = diag.code orelse return;
        const cause = diag.last_cause() orelse "no cause given";
        const text = std.fmt.bufPrint(&guard.renewal_error_buffer, "ZC-{t}: {s}", .{
            code, cause,
        }) catch guard.renewal_error_buffer[0..]; // Cut at the buffer's end.
        guard.renewal_error_length = @intCast(text.len);
    }

    /// A credential step succeeded: there is no renewal error.
    pub fn renewed(guard: *Guard) void {
        guard.renewal_error_length = 0;
    }

    pub fn renewal_error(guard: *const Guard) []const u8 {
        if (guard.renewal_error_length == 0) return "none";
        return guard.renewal_error_buffer[0..guard.renewal_error_length];
    }

    /// Before a new connection: passes when `c`'s certificate is in its window (writing the 3/4
    /// line once), or when `--cert` takes its place. Else ZC-E0811 in `diag`.
    pub fn check(guard: *Guard, c: *Credentials, diag: *Diag) error{Failed}!void {
        assert(c.ready());
        assert(diag.code == null);
        if (fault_on(.check)) return;
        const now_ms = guard.wall.now_ms();
        const window = window_of(c);
        x509.window(window.not_before_ms, window.not_after_ms, now_ms) catch |err| {
            return guard.replace(c, err, window, now_ms, diag);
        };
        const life_ms = window.not_after_ms - window.not_before_ms;
        const late_ms = window.not_after_ms - life_ms / 4;
        if (now_ms < late_ms) return;
        if (guard.warned_ms == window.not_after_ms) return;
        guard.warned_ms = window.not_after_ms;
        var expiry: [20]u8 = undefined;
        guard.say("zcube-agent: the certificate it presents expires at {s} and 3/4 of its " ++
            "life has passed without a renewal; last renewal error: {s}\n", .{
            x509.format_time(&expiry, window.not_after_ms), guard.renewal_error(),
        });
    }

    /// The presented certificate is outside its window: `--cert` in its place, or ZC-E0811.
    fn replace(
        guard: *Guard,
        c: *Credentials,
        err: x509.Error,
        window: x509.Lifetime,
        now_ms: u64,
        diag: *Diag,
    ) error{Failed}!void {
        var why: []const u8 = "--cert was not given";
        if (guard.fallback) |fallback| {
            var trial = c.*;
            defer std.crypto.secureZero(u8, std.mem.asBytes(&trial.key_pair));
            if (fallback.load(fallback.context, &trial, now_ms)) |problem| {
                why = problem;
            } else {
                c.certificate = trial.certificate;
                c.key_pair = trial.key_pair;
                if (guard.noted_ms != window.not_after_ms) {
                    guard.noted_ms = window.not_after_ms;
                    var expiry: [20]u8 = undefined;
                    guard.say("zcube-agent: the certificate it presented {s} (valid to {s}); " ++
                        "presenting --cert until the next renewal\n", .{
                        if (err == error.Expired) "has expired" else "is not valid yet",
                        x509.format_time(&expiry, window.not_after_ms),
                    });
                }
                return;
            }
        }
        const detail: x509.Detail = .{
            .not_before_ms = window.not_before_ms,
            .not_after_ms = window.not_after_ms,
            .now_ms = now_ms,
        };
        x509.raise(diag, err, "the agent", &detail);
        diag.cause("last renewal error: {s}", .{guard.renewal_error()});
        diag.cause("--cert was not used: {s}", .{why});
        diag.fix(.{
            .sentence = "on the server host, issue the node a new certificate and give the " ++
                "agent the two files as --cert and --key (docs/agent.md)",
            .command = "zcube-server ca issue-node NAME --replace",
        });
        return error.Failed;
    }

    fn say(guard: *Guard, comptime format: []const u8, args: anytype) void {
        const line = std.fmt.bufPrint(&guard.line_buffer, format, args) catch
            guard.line_buffer[0..]; // Cut at the buffer's end.
        guard.line_length = @intCast(line.len);
        guard.lines += 1;
        if (guard.silent) return;
        std.Io.File.stderr().writeStreamingAll(guard.io, line) catch {}; // Only a note.
    }

    pub fn last_line(guard: *const Guard) []const u8 {
        return guard.line_buffer[0..guard.line_length];
    }
};

/// The window of the certificate `c` presents.
fn window_of(c: *const Credentials) x509.Lifetime {
    const parsed = x509.parse(c.certificate.slice()) catch unreachable; // `present` or
    // `require_node` verified it before it was presented, and it has not changed since.
    return .{ .not_before_ms = parsed.not_before_ms, .not_after_ms = parsed.not_after_ms };
}

/// `--cert` and `--key` from their files, read when the guard needs them: a certificate written
/// there after the agent started is picked up.
pub const FileFallback = struct {
    io: std.Io,
    cert: []const u8,
    key: []const u8,
    node: []const u8,
    why_buffer: [reason_bytes_max]u8 = undefined,

    pub fn fallback(file: *FileFallback) Fallback {
        return .{ .context = file, .load = load };
    }

    fn load(context: *anyopaque, trial: *Credentials, now_ms: u64) ?[]const u8 {
        const file: *FileFallback = @ptrCast(@alignCast(context));
        var diag: Diag = undefined;
        diag.reset();
        trial.load_identity(file.io, file.cert, file.key, &diag) catch return file.why(&diag);
        trial.require_node(file.cert, file.node, now_ms, &diag) catch return file.why(&diag);
        return null;
    }

    fn why(file: *FileFallback, diag: *const Diag) []const u8 {
        const cause = diag.last_cause() orelse "it could not be used";
        const length = @min(cause.len, file.why_buffer.len);
        @memcpy(file.why_buffer[0..length], cause[0..length]);
        return file.why_buffer[0..length];
    }
};
