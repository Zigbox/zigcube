//! The redaction harness (docs/briefs/c5.md, "Secrets never leave sealed"): a test plants a known
//! secret, runs a path (an API reply, a log, a diagnostic, a bundle) and asks `expect_absent`
//! whether the output holds the secret in any form a careless path would print it: the raw bytes,
//! hex in either case, and base64 (standard and URL-safe, padded or not). A secret embedded in a
//! longer base64 or hex string at any byte offset is found too: base64 is tried at all three
//! alignments, and the forms are searched as substrings. Each form is also searched in the
//! output with whitespace and the JSON escapes `\n`, `\r`, `\t` and `\/` taken out, so base64
//! wrapped at 64 or 76 columns (PEM, MIME) or escaped inside a JSON string is found too.
//!
//! Test-only. It never prints the secret: a failure names the form and the offset.

const std = @import("std");
const assert = std.debug.assert;

pub const secret_bytes_max = 256;

pub const Form = enum {
    raw,
    hex_lower,
    hex_upper,
    base64_standard,
    base64_url,
};

/// `offset` is in the output as searched: with `unwrapped`, the output with whitespace and JSON
/// escapes taken out.
pub const Found = struct { form: Form, offset: usize, unwrapped: bool = false };

/// The first form of `secret` that `haystack` holds, or null. `secret` is at least 8 bytes, so
/// that a short match by chance is not a finding.
pub fn find(haystack: []const u8, secret: []const u8) ?Found {
    assert(secret.len >= 8);
    assert(secret.len <= secret_bytes_max);
    if (find_plain(haystack, secret)) |found| return found;
    const unwrapped = std.testing.allocator.alloc(u8, haystack.len) catch
        @panic("redaction: out of memory"); // Test-only; a failed test, not a missed secret.
    defer std.testing.allocator.free(unwrapped);
    var found = find_plain(unwrap(haystack, unwrapped), secret) orelse return null;
    found.unwrapped = true;
    return found;
}

/// `haystack` without whitespace and with the JSON escapes `\n`, `\r`, `\t` removed and `\/`
/// made `/`, in `out`.
fn unwrap(haystack: []const u8, out: []u8) []const u8 {
    assert(out.len >= haystack.len);
    var length: usize = 0;
    var index: usize = 0;
    while (index < haystack.len) : (index += 1) {
        const byte = haystack[index];
        if (byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n') continue;
        if (byte == '\\' and index + 1 < haystack.len) {
            switch (haystack[index + 1]) {
                'n', 'r', 't' => {
                    index += 1;
                    continue;
                },
                '/' => {
                    index += 1;
                    out[length] = '/';
                    length += 1;
                    continue;
                },
                else => {},
            }
        }
        out[length] = byte;
        length += 1;
    }
    return out[0..length];
}

fn find_plain(haystack: []const u8, secret: []const u8) ?Found {
    if (std.mem.indexOf(u8, haystack, secret)) |offset| return .{ .form = .raw, .offset = offset };
    var hex: [secret_bytes_max * 2]u8 = undefined;
    const lower = std.fmt.bufPrint(&hex, "{x}", .{secret}) catch unreachable; // Fits.
    if (index_ignore_case(haystack, lower)) |found| return found;
    // base64 of the secret at each alignment: the secret preceded by 0, 1 or 2 bytes encodes
    // to a string whose middle (the groups made only of secret bytes) is the same whatever
    // those bytes were. That middle is what a longer encoded string holds.
    for (0..3) |shift| {
        if (base64_core(haystack, secret, shift, .standard)) |found| return found;
        if (base64_core(haystack, secret, shift, .url)) |found| return found;
    }
    return null;
}

/// Fails the test if `haystack` holds `secret` in any form. `what` names the output in the
/// message, never the secret.
pub fn expect_absent(haystack: []const u8, secret: []const u8, what: []const u8) !void {
    if (find(haystack, secret)) |found| {
        const where = if (found.unwrapped) " of the unwrapped text" else "";
        std.debug.print("redaction: {s} holds the secret ({s}) at byte {d}{s}\n", .{
            what, @tagName(found.form), found.offset, where,
        });
        return error.SecretFound;
    }
}

fn index_ignore_case(haystack: []const u8, lower: []const u8) ?Found {
    if (haystack.len < lower.len) return null;
    var offset: usize = 0;
    while (offset + lower.len <= haystack.len) : (offset += 1) {
        const window = haystack[offset..][0..lower.len];
        if (std.ascii.eqlIgnoreCase(window, lower)) {
            const upper = for (window) |byte| {
                if (std.ascii.isUpper(byte)) break true;
            } else false;
            return .{ .form = if (upper) .hex_upper else .hex_lower, .offset = offset };
        }
    }
    return null;
}

const Alphabet = enum { standard, url };

fn base64_core(haystack: []const u8, secret: []const u8, shift: usize, alphabet: Alphabet) ?Found {
    const encoder = switch (alphabet) {
        .standard => std.base64.standard_no_pad.Encoder,
        .url => std.base64.url_safe_no_pad.Encoder,
    };
    var input: [secret_bytes_max + 2]u8 = @splat(0);
    @memcpy(input[shift..][0..secret.len], secret);
    var text: [((secret_bytes_max + 2) / 3 + 1) * 4]u8 = undefined;
    const encoded = encoder.encode(&text, input[0 .. shift + secret.len]);
    // Groups of 3 input bytes encode to 4 characters. Keep the characters whose 6 bits all
    // come from secret bytes: skip the first group if it holds padding bytes before the secret,
    // and the last group if it is partial.
    const first_group: usize = if (shift == 0) 0 else 1;
    const whole_groups = (shift + secret.len) / 3;
    if (whole_groups <= first_group + 1) return null; // Too short to judge at this alignment.
    const core = encoded[first_group * 4 .. whole_groups * 4];
    assert(core.len >= 4);
    const offset = std.mem.indexOf(u8, haystack, core) orelse return null;
    return .{
        .form = if (alphabet == .standard) .base64_standard else .base64_url,
        .offset = offset,
    };
}

const testing = std.testing;

test "every form of a planted secret is found, and its absence is not a finding" {
    // Goal: the harness has teeth. Method: a 32-byte secret is put into a text in each form, at
    // each offset in a longer encoded string, and each must be found; a text without it must
    // not be.
    var secret: [32]u8 = undefined;
    for (&secret, 0..) |*byte, index| byte.* = @intCast((0xa0 + index * 7) % 256);
    try testing.expect(find("nothing secret here at all", &secret) == null);
    try expect_absent("nothing secret here at all", &secret, "clean text");

    var raw_buffer: [128]u8 = undefined;
    const raw = try std.fmt.bufPrint(&raw_buffer, "log: {s} end", .{&secret});
    var buffer: [1024]u8 = undefined;
    try testing.expectEqual(Form.raw, find(raw, &secret).?.form);
    const lower = try std.fmt.bufPrint(&buffer, "key={x}", .{&secret});
    try testing.expectEqual(Form.hex_lower, find(lower, &secret).?.form);
    const upper = try std.fmt.bufPrint(&buffer, "key={X}", .{&secret});
    try testing.expectEqual(Form.hex_upper, find(upper, &secret).?.form);

    // Inside a longer base64 string, after 0..5 other bytes, in both alphabets and with padding.
    for (0..6) |before| {
        var input: [64]u8 = @splat(0x5c);
        @memcpy(input[before..][0..secret.len], &secret);
        const length = before + secret.len + 1;
        var text: [128]u8 = undefined;
        const standard = std.base64.standard.Encoder.encode(&text, input[0..length]);
        try testing.expect(find(standard, &secret) != null);
        const url = std.base64.url_safe_no_pad.Encoder.encode(&text, input[0..length]);
        try testing.expect(find(url, &secret) != null);
    }
    // `expect_absent` on `raw` would fail through `find`, which the checks above cover; it is not
    // called here because its message on stderr counts as a failure of the test step.
    try testing.expectEqual(@as(usize, 5), find(raw, &secret).?.offset);
}

test "base64 wrapped at 64 and 76 columns, or escaped in JSON, is found" {
    // Goal: a PEM block or a JSON-escaped PEM does not hide a secret (ruling 3). Method: a
    // 200-byte secret inside a longer base64 string, wrapped at 64 columns with "\n", at 76 with
    // "\r\n", and as a JSON string ("\\n" between lines, "\\/" for each '/'): each is found;
    // the same text with one byte of the secret changed is not.
    var secret: [200]u8 = undefined;
    for (&secret, 0..) |*byte, index| byte.* = @intCast((index * 37 + 11) % 256);
    var input: [208]u8 = @splat(0x5c);
    @memcpy(input[5..][0..secret.len], &secret);
    var encoded_buffer: [400]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(&encoded_buffer, &input);
    try testing.expect(std.mem.indexOfScalar(u8, encoded, '/') != null);
    var text: [1024]u8 = undefined;
    for ([_]struct { width: usize, eol: []const u8 }{
        .{ .width = 64, .eol = "\n" },
        .{ .width = 76, .eol = "\r\n" },
        .{ .width = 64, .eol = "\\n" },
    }) |shape| {
        const pem = wrap(&text, encoded, shape.width, shape.eol, shape.eol[0] == '\\');
        try testing.expect(std.mem.indexOf(u8, pem, shape.eol) != null);
        const found = find(pem, &secret).?;
        try testing.expect(found.unwrapped);
        try testing.expectEqual(Form.base64_standard, found.form);
    }
    var other = secret;
    other[100] ^= 1;
    const pem = wrap(&text, encoded, 64, "\n", false);
    try testing.expect(find(pem, &other) == null);
}

/// `encoded` in lines of `width`, each ended by `eol`; with `json`, each '/' written "\\/".
fn wrap(out: []u8, encoded: []const u8, width: usize, eol: []const u8, json: bool) []const u8 {
    var length: usize = 0;
    for (encoded, 0..) |byte, index| {
        if (index > 0 and index % width == 0) {
            @memcpy(out[length..][0..eol.len], eol);
            length += eol.len;
        }
        if (json and byte == '/') {
            out[length] = '\\';
            length += 1;
        }
        out[length] = byte;
        length += 1;
    }
    return out[0..length];
}
