//! The redaction harness (docs/briefs/c5.md, "Secrets never leave sealed"): a test plants a known
//! secret, runs a path (an API reply, a log, a diagnostic, a bundle) and asks `expect_absent`
//! whether the output holds the secret in any form a careless path would print it: the raw bytes,
//! hex in either case, and base64 (standard and URL-safe, padded or not). A secret embedded in a
//! longer base64 or hex string at any byte offset is found too: base64 is tried at all three
//! alignments, and the forms are searched as substrings.
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

pub const Found = struct { form: Form, offset: usize };

/// The first form of `secret` that `haystack` holds, or null. `secret` is at least 8 bytes, so
/// that a short match by chance is not a finding.
pub fn find(haystack: []const u8, secret: []const u8) ?Found {
    assert(secret.len >= 8);
    assert(secret.len <= secret_bytes_max);
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
        std.debug.print("redaction: {s} holds the secret ({s}) at byte {d}\n", .{
            what, @tagName(found.form), found.offset,
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
    try testing.expectError(error.SecretFound, expect_absent(raw, &secret, "a planted log"));
}
