//! Host names of public services (docs/briefs/c5.md, "Host names"): one function that
//! canonicalizes a name at apply, and compares the TLS server name and the HTTP `Host` header
//! with it. A canonical name is ASCII, lowercase, without a trailing dot, of at least two labels,
//! each 1 to 63 letters, digits or hyphens with no hyphen at either end, and at most 253 bytes.
//! Punycode labels (`xn--`) are taken as given. A Unicode name is refused; `punycode` spells it
//! for the fix. IP literals, wildcards, empty labels and `localhost` are refused.
//!
//! Core code: no allocation, no I/O.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");

const host_bytes_max = constants.edge_host_bytes_max;
const label_bytes_max = constants.edge_host_label_bytes_max;

/// Which rule a name breaks. `describe` says it in a sentence.
pub const Error = error{
    Empty,
    TooLong,
    NotAscii,
    IpLiteral,
    Wildcard,
    Localhost,
    OneLabel,
    EmptyLabel,
    LabelTooLong,
    LabelHyphen,
    LabelCharacter,
    Port,
};

pub const Name = [host_bytes_max]u8;

/// The canonical spelling of `name` in `out`, or the first rule it breaks.
pub fn canonicalize(out: *Name, name: []const u8) Error![]const u8 {
    if (name.len == 0) return error.Empty;
    if (name.len > constants.edge_host_input_bytes_max) return error.TooLong;
    if (std.mem.indexOfScalar(u8, name, '*') != null) return error.Wildcard;
    // Only an IPv6 literal has a colon or a bracket in it.
    if (std.mem.indexOfAny(u8, name, ":[]") != null) return error.IpLiteral;
    for (name) |byte| {
        if (byte >= 0x80) return error.NotAscii;
    }
    var bare = name;
    if (bare[bare.len - 1] == '.') bare = bare[0 .. bare.len - 1];
    if (bare.len == 0) return error.Empty;
    if (bare.len > host_bytes_max) return error.TooLong;
    const lower = std.ascii.lowerString(out[0..bare.len], bare);
    if (is_localhost(lower)) return error.Localhost;
    const labels = try check_labels(lower);
    assert(labels >= 1);
    if (labels == 1) return error.OneLabel;
    if (is_number_label(last_label(lower))) return error.IpLiteral;
    assert(lower.len <= host_bytes_max);
    return lower;
}

/// The `Host` header's name, canonical: `:443` is stripped, any other port refused.
pub fn from_host_header(out: *Name, value: []const u8) Error![]const u8 {
    if (value.len == 0) return error.Empty;
    if (value[0] == '[') return error.IpLiteral;
    const colon = std.mem.lastIndexOfScalar(u8, value, ':') orelse return canonicalize(out, value);
    if (std.mem.indexOfScalar(u8, value[0..colon], ':') != null) return error.IpLiteral;
    if (!std.mem.eql(u8, value[colon + 1 ..], "443")) return error.Port;
    return canonicalize(out, value[0..colon]);
}

/// Whether two names are the same host: both canonicalized, then compared byte for byte.
pub fn same(a: []const u8, b: []const u8) bool {
    var a_out: Name = undefined;
    var b_out: Name = undefined;
    const a_name = canonicalize(&a_out, a) catch return false;
    const b_name = canonicalize(&b_out, b) catch return false;
    return std.mem.eql(u8, a_name, b_name);
}

/// The rule a refused name breaks, as a sentence for the cause line.
pub fn describe(err: Error) []const u8 {
    return switch (err) {
        error.Empty => "the name is empty",
        error.TooLong => "the name is longer than 253 bytes",
        error.NotAscii => "the name is not ASCII; write it in punycode (xn--)",
        error.IpLiteral => "the name is an IP address, not a DNS name",
        error.Wildcard => "the name is a wildcard; name each host",
        error.Localhost => "the name is localhost, which has no public certificate",
        error.OneLabel => "the name has one label; a public name has at least two",
        error.EmptyLabel => "the name has an empty label (two dots in a row, or a leading dot)",
        error.LabelTooLong => "a label is longer than 63 bytes",
        error.LabelHyphen => "a label starts or ends with a hyphen",
        error.LabelCharacter => "a label holds a character other than a letter, digit or hyphen",
        error.Port => "the Host header names a port other than 443",
    };
}

/// Checks each label and returns how many there are.
fn check_labels(name: []const u8) Error!u32 {
    assert(name.len > 0);
    var count: u32 = 0;
    var labels = std.mem.splitScalar(u8, name, '.');
    while (labels.next()) |label| {
        count += 1;
        if (label.len == 0) return error.EmptyLabel;
        if (label.len > label_bytes_max) return error.LabelTooLong;
        if (label[0] == '-') return error.LabelHyphen;
        if (label[label.len - 1] == '-') return error.LabelHyphen;
        for (label) |byte| {
            const ok = std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '-';
            if (!ok) return error.LabelCharacter;
        }
    }
    assert(count <= name.len);
    return count;
}

fn is_localhost(name: []const u8) bool {
    if (std.mem.eql(u8, name, "localhost")) return true;
    return std.mem.endsWith(u8, name, ".localhost");
}

fn last_label(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    return name[dot + 1 ..];
}

/// Whether a browser's URL parser (WHATWG URL, "ends in a number") reads the last label as a
/// number, and so the whole host as IPv4: all decimal digits, or `0x` and hex digits (none
/// included). `label` is lowercase.
fn is_number_label(label: []const u8) bool {
    if (all_digits(label)) return true;
    if (!std.mem.startsWith(u8, label, "0x")) return false;
    for (label[2..]) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

fn all_digits(label: []const u8) bool {
    if (label.len == 0) return false;
    for (label) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

// ---- Punycode, for the fix line (RFC 3492) -----------------------------------------------------

const base: u32 = 36;
const t_min: u32 = 1;
const t_max: u32 = 26;
const skew: u32 = 38;
const damp: u32 = 700;
const initial_bias: u32 = 72;
const initial_n: u32 = 128;

/// The punycode spelling of a Unicode name (each non-ASCII label as `xn--...`, ASCII letters
/// lowercased), or null when the name is not UTF-8 or its spelling does not fit 253 bytes. No
/// Unicode mapping (UTS 46) is applied: the fix shows the name as given, encoded.
pub fn punycode(out: *Name, name: []const u8) ?[]const u8 {
    var bare = name;
    if (bare.len > 0 and bare[bare.len - 1] == '.') bare = bare[0 .. bare.len - 1];
    if (bare.len == 0) return null;
    if (bare.len > constants.edge_host_input_bytes_max) return null;
    var length: u32 = 0;
    var labels = std.mem.splitScalar(u8, bare, '.');
    var first = true;
    while (labels.next()) |label| {
        if (!first) length = append(out, length, ".") orelse return null;
        first = false;
        length = encode_label(out, length, label) orelse return null;
    }
    assert(length <= host_bytes_max);
    return out[0..length];
}

/// Writes one label at `out[at..]`: as it is (lowercased) when ASCII, else `xn--` and its
/// punycode. Returns the new length, or null when it does not fit or is not UTF-8.
fn encode_label(out: *Name, at: u32, label: []const u8) ?u32 {
    var points: [constants.edge_host_input_bytes_max]u21 = undefined;
    var count: u32 = 0;
    var ascii = true;
    var view = std.unicode.Utf8View.init(label) catch return null;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |point| {
        assert(count < points.len);
        points[count] = if (point < 0x80) std.ascii.toLower(@intCast(point)) else point;
        if (point >= 0x80) ascii = false;
        count += 1;
    }
    var length = at;
    if (ascii) {
        for (points[0..count]) |point| {
            length = append(out, length, &.{@intCast(point)}) orelse return null;
        }
        return length;
    }
    length = append(out, length, "xn--") orelse return null;
    return encode_points(out, length, points[0..count]);
}

/// RFC 3492 section 6.3: the basic code points, a delimiter, then the deltas.
fn encode_points(out: *Name, at: u32, points: []const u21) ?u32 {
    var length = at;
    var basic: u32 = 0;
    for (points) |point| {
        if (point >= 0x80) continue;
        length = append(out, length, &.{@intCast(point)}) orelse return null;
        basic += 1;
    }
    if (basic > 0) length = append(out, length, "-") orelse return null;
    var n: u32 = initial_n;
    var delta: u64 = 0;
    var bias: u32 = initial_bias;
    var handled: u32 = basic;
    while (handled < points.len) {
        var next: u32 = std.math.maxInt(u21);
        for (points) |point| {
            if (point >= n and point < next) next = point;
        }
        delta += @as(u64, next - n) * (handled + 1);
        n = next;
        for (points) |point| {
            if (point < n) delta += 1;
            if (point != n) continue;
            length = encode_delta(out, length, delta, bias) orelse return null;
            bias = adapt(delta, handled + 1, handled == basic);
            delta = 0;
            handled += 1;
        }
        delta += 1;
        n += 1;
    }
    return length;
}

/// One variable-length integer (section 3.3) with thresholds from `bias`.
fn encode_delta(out: *Name, at: u32, delta: u64, bias: u32) ?u32 {
    var length = at;
    var q = delta;
    var k: u32 = base;
    while (true) : (k += base) {
        const t: u32 = if (k <= bias) t_min else if (k >= bias + t_max) t_max else k - bias;
        if (q < t) break;
        const digit = t + @as(u32, @intCast((q - t) % (base - t)));
        length = append(out, length, &.{digit_char(digit)}) orelse return null;
        q = (q - t) / (base - t);
        if (q > std.math.maxInt(u32)) return null;
    }
    return append(out, length, &.{digit_char(@intCast(q))});
}

fn adapt(delta_in: u64, points: u32, first: bool) u32 {
    assert(points > 0);
    var delta = if (first) delta_in / damp else delta_in / 2;
    delta += delta / points;
    var k: u32 = 0;
    while (delta > ((base - t_min) * t_max) / 2) : (k += base) delta /= base - t_min;
    return k + @as(u32, @intCast(((base - t_min + 1) * delta) / (delta + skew)));
}

fn digit_char(digit: u32) u8 {
    assert(digit < base);
    return if (digit < 26) @intCast('a' + digit) else @intCast('0' + digit - 26);
}

fn append(out: *Name, at: u32, bytes: []const u8) ?u32 {
    if (at + bytes.len > out.len) return null;
    @memcpy(out[at..][0..bytes.len], bytes);
    return at + @as(u32, @intCast(bytes.len));
}

// ---- Tests -------------------------------------------------------------------------------------

const testing = std.testing;

fn repeat(comptime text: []const u8, comptime count: u32) [text.len * count]u8 {
    @setEvalBranchQuota(10_000);
    var out: [text.len * count]u8 = undefined;
    for (0..count) |index| @memcpy(out[index * text.len ..][0..text.len], text);
    return out;
}

test "edge_host: canonical names" {
    // Goal: each spelling of a good name gives one canonical name. Method: a table.
    const cases = [_]struct { name: []const u8, want: []const u8 }{
        .{ .name = "example.com", .want = "example.com" },
        .{ .name = "Example.COM", .want = "example.com" },
        .{ .name = "example.com.", .want = "example.com" },
        .{ .name = "a-b.c-d.example", .want = "a-b.c-d.example" },
        .{ .name = "xn--bcher-kva.example", .want = "xn--bcher-kva.example" },
        .{ .name = "XN--BCHER-KVA.example", .want = "xn--bcher-kva.example" },
        .{ .name = "123.example.com", .want = "123.example.com" },
        .{ .name = "a.b", .want = "a.b" },
        // Only a last label of `0x` and hex digits is a number to a browser.
        .{ .name = "example.0xg", .want = "example.0xg" },
        .{ .name = "0x1.example", .want = "0x1.example" },
    };
    for (cases) |case| {
        var out: Name = undefined;
        try testing.expectEqualStrings(case.want, try canonicalize(&out, case.name));
    }
}

test "edge_host: each rule refuses" {
    // Goal: every rule has a name that breaks it and only it. Method: a table of refusals.
    const label_64 = comptime repeat("a", 64);
    const name_254 = comptime repeat(repeat("a", 62) ++ ".", 4) ++ "ab";
    comptime assert(name_254.len == 254);
    const cases = [_]struct { name: []const u8, want: Error }{
        .{ .name = "", .want = error.Empty },
        .{ .name = ".", .want = error.Empty },
        .{ .name = name_254, .want = error.TooLong },
        .{ .name = &comptime repeat("a", 2000), .want = error.TooLong },
        .{ .name = "b\xc3\xbccher.example", .want = error.NotAscii },
        .{ .name = "192.0.2.1", .want = error.IpLiteral },
        .{ .name = "1.2.3.0x4", .want = error.IpLiteral },
        .{ .name = "example.0x1", .want = error.IpLiteral },
        .{ .name = "example.0X1F", .want = error.IpLiteral },
        .{ .name = "example.0x", .want = error.IpLiteral },
        .{ .name = "2001:db8::1", .want = error.IpLiteral },
        .{ .name = "[2001:db8::1]", .want = error.IpLiteral },
        .{ .name = "*.example.com", .want = error.Wildcard },
        .{ .name = "localhost", .want = error.Localhost },
        .{ .name = "app.localhost", .want = error.Localhost },
        .{ .name = "LOCALHOST.", .want = error.Localhost },
        .{ .name = "example", .want = error.OneLabel },
        .{ .name = "a..example", .want = error.EmptyLabel },
        .{ .name = ".example.com", .want = error.EmptyLabel },
        .{ .name = "example.com..", .want = error.EmptyLabel },
        .{ .name = label_64 ++ ".example", .want = error.LabelTooLong },
        .{ .name = "-a.example", .want = error.LabelHyphen },
        .{ .name = "a-.example", .want = error.LabelHyphen },
        .{ .name = "a_b.example", .want = error.LabelCharacter },
        .{ .name = "a b.example", .want = error.LabelCharacter },
    };
    for (cases) |case| {
        var out: Name = undefined;
        try testing.expectError(case.want, canonicalize(&out, case.name));
        try testing.expect(describe(case.want).len > 0);
    }
}

test "edge_host: the longest names are taken" {
    // Goal: the bounds are inclusive. Method: a 63-byte label and a 253-byte name.
    const label_63 = comptime repeat("a", 63);
    const name_253 = comptime repeat(repeat("a", 62) ++ ".", 4) ++ "a";
    comptime assert(name_253.len == 253);
    var out: Name = undefined;
    try testing.expectEqual(@as(usize, 71), (try canonicalize(&out, label_63 ++ ".example")).len);
    try testing.expectEqual(@as(usize, 253), (try canonicalize(&out, name_253)).len);
    try testing.expectEqual(@as(usize, 253), (try canonicalize(&out, name_253 ++ ".")).len);
}

test "edge_host: the Host header" {
    // Goal: `:443` is stripped and any other port refused. Method: a table.
    var out: Name = undefined;
    try testing.expectEqualStrings("example.com", try from_host_header(&out, "Example.com:443"));
    try testing.expectEqualStrings("example.com", try from_host_header(&out, "example.com"));
    try testing.expectError(error.Port, from_host_header(&out, "example.com:8443"));
    try testing.expectError(error.Port, from_host_header(&out, "example.com:"));
    try testing.expectError(error.Port, from_host_header(&out, "example.com:0443"));
    try testing.expectError(error.IpLiteral, from_host_header(&out, "[::1]:443"));
    try testing.expectError(error.IpLiteral, from_host_header(&out, "::1"));
    try testing.expectError(error.IpLiteral, from_host_header(&out, "192.0.2.1:443"));
    try testing.expectError(error.Empty, from_host_header(&out, ""));
    try testing.expect(same("Example.com.", "example.COM"));
    try testing.expect(!same("example.com", "example.org"));
    try testing.expect(!same("localhost", "localhost"));
}

test "edge_host: punycode for the fix" {
    // Goal: a Unicode name's fix gives its punycode spelling. Method: RFC 3492's examples
    // and well-known names.
    const cases = [_]struct { name: []const u8, want: []const u8 }{
        .{ .name = "b\xc3\xbccher.example", .want = "xn--bcher-kva.example" },
        .{ .name = "M\xc3\xbcnchen.de.", .want = "xn--mnchen-3ya.de" },
        .{ .name = "\xe4\xbe\x8b\xe3\x81\x88.jp", .want = "xn--r8jz45g.jp" },
        .{ .name = "example.com", .want = "example.com" },
    };
    for (cases) |case| {
        var out: Name = undefined;
        try testing.expectEqualStrings(case.want, punycode(&out, case.name).?);
    }
    var out: Name = undefined;
    try testing.expect(punycode(&out, "\xff.example") == null);
    try testing.expect(punycode(&out, "") == null);
    try testing.expect(punycode(&out, &comptime repeat("\xc3\xbc", 300)) == null);
}
