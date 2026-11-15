//! Strict DER, just enough for `x509.zig` and `x509_identity.zig`. Core code: no allocation, no
//! recursion, no clock. The `Reader` takes one tag-length-value at a time from a byte slice and
//! refuses every non-DER form (high tag numbers, indefinite or non-minimal lengths, a value that
//! runs past its parent); the `Writer` builds a value back to front so that a length is known
//! before its header is written, and never needs a second pass.

const std = @import("std");
const assert = std.debug.assert;

pub const Error = error{
    /// Not DER: a form this code does not accept, or a value cut short.
    Malformed,
    /// The output buffer is too small.
    NoSpace,
};

pub const tag_boolean: u8 = 0x01;
pub const tag_integer: u8 = 0x02;
pub const tag_bit_string: u8 = 0x03;
pub const tag_octet_string: u8 = 0x04;
pub const tag_oid: u8 = 0x06;
pub const tag_enumerated: u8 = 0x0A;
pub const tag_utf8_string: u8 = 0x0C;
pub const tag_utc_time: u8 = 0x17;
pub const tag_generalized_time: u8 = 0x18;
pub const tag_sequence: u8 = 0x30;
pub const tag_set: u8 = 0x31;

/// A byte range of the input, `start` inclusive and `end` exclusive.
pub const Span = struct {
    start: u32,
    end: u32,

    pub fn len(span: Span) u32 {
        assert(span.end >= span.start);
        return span.end - span.start;
    }

    pub fn of(span: Span, bytes: []const u8) []const u8 {
        assert(span.end <= bytes.len);
        return bytes[span.start..span.end];
    }
};

/// One element: the whole TLV (`whole`) and its value (`value`).
pub const Element = struct {
    tag: u8,
    whole: Span,
    value: Span,
};

pub const Reader = struct {
    bytes: []const u8,
    position: u32,
    end: u32,

    /// A reader over `bytes[span.start..span.end]`.
    pub fn init(bytes: []const u8, span: Span) Reader {
        assert(span.start <= span.end);
        assert(span.end <= bytes.len);
        return .{ .bytes = bytes, .position = span.start, .end = span.end };
    }

    pub fn finished(reader: *const Reader) bool {
        assert(reader.position <= reader.end);
        return reader.position == reader.end;
    }

    /// The next element, whatever its tag. Lengths up to 65535 (two length bytes) are read; the
    /// certificate bound is far below that.
    pub fn next(reader: *Reader) Error!Element {
        assert(reader.position <= reader.end);
        const start = reader.position;
        const remaining = reader.end - start;
        if (remaining < 2) return error.Malformed;
        const tag = reader.bytes[start];
        // A tag number of 31 or more continues in further bytes; no such tag is used.
        if (tag & 0x1F == 0x1F) return error.Malformed;
        const first = reader.bytes[start + 1];
        var header: u32 = 2;
        var length: u32 = first;
        if (first >= 0x80) {
            // Long form: 0x80 alone is indefinite, and more than two length bytes is unused.
            const count = first & 0x7F;
            if (count == 0 or count > 2) return error.Malformed;
            if (remaining < 2 + count) return error.Malformed;
            length = 0;
            for (0..count) |i| length = (length << 8) | reader.bytes[start + 2 + i];
            header = 2 + count;
            // DER uses the shortest form: a long form for a value under 128, or with a leading
            // zero byte, is not canonical.
            if (length < 0x80) return error.Malformed;
            if (count == 2 and length < 0x100) return error.Malformed;
        }
        if (length > remaining - header) return error.Malformed;
        const value_start = start + header;
        reader.position = value_start + length;
        return .{
            .tag = tag,
            .whole = .{ .start = start, .end = reader.position },
            .value = .{ .start = value_start, .end = reader.position },
        };
    }

    /// The next element, which must have `tag`.
    pub fn expect(reader: *Reader, tag: u8) Error!Element {
        const element = try reader.next();
        if (element.tag != tag) return error.Malformed;
        return element;
    }

    /// Fails unless every byte was read: DER has no trailing bytes.
    pub fn finish(reader: *const Reader) Error!void {
        if (!reader.finished()) return error.Malformed;
    }
};

/// A non-negative INTEGER's content with no redundant leading byte: returns the magnitude bytes
/// (without a sign-padding zero). Refuses empty, negative and non-minimal forms.
pub fn unsigned_magnitude(content: []const u8) Error![]const u8 {
    if (content.len == 0) return error.Malformed;
    if (content[0] & 0x80 != 0) return error.Malformed;
    if (content.len > 1) {
        // A leading zero is allowed only to keep the sign bit clear.
        if (content[0] == 0 and content[1] & 0x80 == 0) return error.Malformed;
    }
    if (content[0] == 0 and content.len > 1) return content[1..];
    return content;
}

/// An INTEGER in 0..2^63-1, minimal.
pub fn unsigned_u63(content: []const u8) Error!u64 {
    const magnitude = try unsigned_magnitude(content);
    if (magnitude.len > 8) return error.Malformed;
    var value: u64 = 0;
    for (magnitude) |byte| value = (value << 8) | byte;
    if (value >> 63 != 0) return error.Malformed;
    return value;
}

/// Writes back to front into a fixed buffer. `position` is where the finished value starts.
pub const Writer = struct {
    buffer: []u8,
    position: u32,

    pub fn init(buffer: []u8) Writer {
        assert(buffer.len < 65536);
        return .{ .buffer = buffer, .position = @intCast(buffer.len) };
    }

    /// The bytes written so far.
    pub fn written(writer: *const Writer) []const u8 {
        return writer.buffer[writer.position..];
    }

    pub fn mark(writer: *const Writer) u32 {
        return writer.position;
    }

    pub fn prepend(writer: *Writer, bytes: []const u8) Error!void {
        if (bytes.len > writer.position) return error.NoSpace;
        writer.position -= @intCast(bytes.len);
        @memcpy(writer.buffer[writer.position..][0..bytes.len], bytes);
    }

    /// Wraps everything written since `since` (a `mark`) in a TLV with `tag`.
    pub fn close(writer: *Writer, tag: u8, since: u32) Error!void {
        assert(since >= writer.position);
        assert(since <= writer.buffer.len);
        const length = since - writer.position;
        var header: [4]u8 = undefined;
        var size: usize = 0;
        if (length < 0x80) {
            header[0] = tag;
            header[1] = @intCast(length);
            size = 2;
        } else if (length < 0x100) {
            header = .{ tag, 0x81, @intCast(length), 0 };
            size = 3;
        } else {
            header = .{ tag, 0x82, @intCast(length >> 8), @intCast(length & 0xFF) };
            size = 4;
        }
        try writer.prepend(header[0..size]);
    }

    /// A whole element with the given content.
    pub fn element(writer: *Writer, tag: u8, content: []const u8) Error!void {
        const since = writer.mark();
        try writer.prepend(content);
        try writer.close(tag, since);
    }

    /// An INTEGER 0..2^63-1, minimal.
    pub fn unsigned(writer: *Writer, value: u64) Error!void {
        assert(value >> 63 == 0);
        var bytes: [9]u8 = @splat(0);
        std.mem.writeInt(u64, bytes[1..9], value, .big);
        var skip: usize = 0;
        // Drop leading zeros but keep one when the next byte has its high bit set.
        while (skip < 8 and bytes[skip] == 0 and bytes[skip + 1] & 0x80 == 0) skip += 1;
        try writer.element(tag_integer, bytes[skip..]);
    }
};

test "reader refuses every non-DER form and writer round-trips lengths" {
    // Goal: the DER layer accepts only the shortest forms. Method: hand-built bad encodings, then
    // values around the 127/128 and 255/256 length boundaries through writer and reader.
    var reader = Reader.init(&.{ 0x30, 0x80, 0x00, 0x00 }, .{ .start = 0, .end = 4 });
    try std.testing.expectError(error.Malformed, reader.next());
    reader = Reader.init(&.{ 0x04, 0x81, 0x05, 1, 2, 3, 4, 5 }, .{ .start = 0, .end = 8 });
    try std.testing.expectError(error.Malformed, reader.next());
    var padded: [148]u8 = @splat(0);
    padded[0..4].* = .{ 0x04, 0x82, 0x00, 0x90 };
    reader = Reader.init(&padded, .{ .start = 0, .end = 148 });
    try std.testing.expectError(error.Malformed, reader.next());
    reader = Reader.init(&.{ 0x1F, 0x01, 0x00 }, .{ .start = 0, .end = 3 });
    try std.testing.expectError(error.Malformed, reader.next());
    reader = Reader.init(&.{ 0x04, 0x05, 1, 2 }, .{ .start = 0, .end = 4 });
    try std.testing.expectError(error.Malformed, reader.next());

    var buffer: [600]u8 = undefined;
    for ([_]usize{ 0, 1, 127, 128, 255, 256, 400 }) |length| {
        var writer = Writer.init(&buffer);
        const content: [400]u8 = @splat(7);
        try writer.element(tag_octet_string, content[0..length]);
        var read = Reader.init(writer.written(), .{
            .start = 0,
            .end = @intCast(writer.written().len),
        });
        const element = try read.expect(tag_octet_string);
        try std.testing.expectEqual(@as(u32, @intCast(length)), element.value.len());
        try read.finish();
    }
}

test "unsigned integers are minimal in both directions" {
    // Goal: writer and `unsigned_u63` agree and refuse padding. Method: boundary values.
    var buffer: [16]u8 = undefined;
    for ([_]u64{ 0, 1, 127, 128, 255, 256, 0x7FFF_FFFF, 1 << 62, (1 << 63) - 1 }) |value| {
        var writer = Writer.init(&buffer);
        try writer.unsigned(value);
        var reader = Reader.init(writer.written(), .{
            .start = 0,
            .end = @intCast(writer.written().len),
        });
        const element = try reader.expect(tag_integer);
        try std.testing.expectEqual(value, try unsigned_u63(element.value.of(writer.written())));
    }
    try std.testing.expectError(error.Malformed, unsigned_u63(&.{}));
    try std.testing.expectError(error.Malformed, unsigned_u63(&.{ 0x00, 0x01 }));
    try std.testing.expectError(error.Malformed, unsigned_u63(&.{0x80}));
    try std.testing.expectError(error.Malformed, unsigned_u63(&.{
        0x00, 0x80, 0, 0, 0, 0, 0, 0, 0,
    }));
}
