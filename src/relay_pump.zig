//! One direction of a relayed connection: the bytes read from one socket and not yet written to
//! the other, and how many have gone through. Pure state, no sockets: `relay.zig` does the I/O
//! and tells this what the reads and writes did, and `relay_fuzz.zig` drives it with short
//! reads and writes. (B3 slice 2, docs/briefs/b3.md.)
//!
//! The rules: a read is only asked for when the buffer is empty (so a slow writer holds the
//! reader, and memory is the one buffer); no more than `limit` bytes ever go through, and a read
//! is never asked for more than the room left under it; an end of input is kept until the
//! buffer is empty, so no byte is dropped by the end that follows it.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");

pub const Pipe = struct {
    buffer: [constants.relay_buffer_bytes]u8 = undefined,
    /// `buffer[start..end]` is read and not yet written.
    start: u32 = 0,
    end: u32 = 0,
    /// Bytes written out so far.
    moved: u64 = 0,
    limit: u64 = constants.relay_connection_bytes_max,
    /// The source ended: nothing more will be read.
    eof: bool = false,

    pub fn pending(pipe: *const Pipe) usize {
        assert(pipe.start <= pipe.end);
        return @as(usize, pipe.end - pipe.start);
    }

    /// Bytes still allowed to enter the buffer: the limit less what went out and what waits.
    fn room(pipe: *const Pipe) u64 {
        const taken = pipe.moved + pipe.pending();
        assert(taken <= pipe.limit);
        return pipe.limit - taken;
    }

    /// The limit is reached: everything it allows has been written, and the source is not at its
    /// end (an end exactly at the limit is a clean end, not a bound).
    pub fn exhausted(pipe: *const Pipe) bool {
        return pipe.moved == pipe.limit and pipe.pending() == 0 and !pipe.eof;
    }

    /// Whether to wait for the source to be readable.
    pub fn wants_read(pipe: *const Pipe) bool {
        return !pipe.eof and pipe.pending() == 0 and pipe.room() > 0;
    }

    /// Where the next read goes, at most `room` bytes of it.
    pub fn read_into(pipe: *Pipe) []u8 {
        assert(pipe.wants_read());
        const size: usize = @intCast(@min(pipe.buffer.len, pipe.room()));
        assert(size > 0);
        return pipe.buffer[0..size];
    }

    /// A read gave `count` bytes; 0 is the end of the source.
    pub fn fed(pipe: *Pipe, count: usize) void {
        assert(pipe.pending() == 0);
        assert(count <= pipe.buffer.len);
        assert(count <= pipe.room());
        if (count == 0) {
            pipe.eof = true;
            return;
        }
        pipe.start = 0;
        pipe.end = @intCast(count);
    }

    /// Whether to wait for the sink to be writable.
    pub fn wants_write(pipe: *const Pipe) bool {
        return pipe.pending() > 0;
    }

    pub fn write_from(pipe: *const Pipe) []const u8 {
        assert(pipe.wants_write());
        return pipe.buffer[pipe.start..pipe.end];
    }

    /// A write took `count` bytes, possibly fewer than offered.
    pub fn drained(pipe: *Pipe, count: usize) void {
        assert(count > 0);
        assert(count <= pipe.pending());
        pipe.start += @intCast(count);
        pipe.moved += count;
        assert(pipe.moved <= pipe.limit);
        if (pipe.start == pipe.end) {
            pipe.start = 0;
            pipe.end = 0;
        }
    }

    /// Everything the source gave has been written and it has nothing more.
    pub fn finished(pipe: *const Pipe) bool {
        return pipe.eof and pipe.pending() == 0;
    }
};

test "a pipe holds a byte until it is written, and keeps an end of input behind it" {
    var pipe: Pipe = .{ .limit = 100 };
    try std.testing.expect(pipe.wants_read());
    @memcpy(pipe.read_into()[0..3], "abc");
    pipe.fed(3);
    try std.testing.expect(!pipe.wants_read());
    try std.testing.expectEqualStrings("abc", pipe.write_from());
    pipe.drained(1);
    try std.testing.expectEqualStrings("bc", pipe.write_from());
    pipe.drained(2);
    try std.testing.expect(pipe.wants_read());
    pipe.fed(0);
    try std.testing.expect(pipe.finished());
    try std.testing.expect(!pipe.exhausted());
    try std.testing.expectEqual(@as(u64, 3), pipe.moved);
}

test "a pipe never reads past its limit and says when it is spent" {
    var pipe: Pipe = .{ .limit = 5 };
    try std.testing.expectEqual(@as(usize, 5), pipe.read_into().len);
    pipe.fed(5);
    pipe.drained(5);
    try std.testing.expect(!pipe.wants_read());
    try std.testing.expect(pipe.exhausted());
}
