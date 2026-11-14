//! A second oracle for `x509_fuzz.zig`: a naive decoder of the `cluster` profile that shares no
//! code with `x509.zig`'s parser or `x509_der.zig`'s reader. It walks the DER by fixed positions,
//! checks the meaning of each field in plain code, and calls the writer (`x509.reencode`) only to
//! ask whether the bytes are what the writer would make of those fields; the round trip is what
//! catches non-minimal lengths, other orders and non-canonical times. Test code only.

const std = @import("std");
const x509 = @import("x509.zig");
const der = @import("x509_der.zig");
const identity_mod = @import("x509_identity.zig");
const constants = @import("constants.zig");

const Span = der.Span;

/// What the naive decoder accepted, for comparison with `x509.parse`.
pub const Verdict = struct {
    kind: x509.Kind,
    not_before_ms: u64,
    not_after_ms: u64,
    name: Span,
};

const Element = struct { tag: u8, value: Span, end: u32 };

/// One TLV at `at`, with any length form; `null` when it runs past `limit`.
fn element(bytes: []const u8, at: u32, limit: u32) ?Element {
    if (at + 2 > limit) return null;
    const tag = bytes[at];
    const first = bytes[at + 1];
    var start = at + 2;
    var length: u64 = first;
    if (first & 0x80 != 0) {
        const count = first & 0x7F;
        if (count == 0 or count > 4) return null;
        if (start + count > limit) return null;
        length = 0;
        for (bytes[start .. start + count]) |byte| length = length * 256 + byte;
        start += count;
    }
    if (start + length > limit) return null;
    const end: u32 = @intCast(start + length);
    return .{ .tag = tag, .value = .{ .start = start, .end = end }, .end = end };
}

/// The children of a constructed element, at most `out.len`; `null` on any overrun.
fn children(bytes: []const u8, parent: Span, out: []Element) ?[]Element {
    var at = parent.start;
    var count: usize = 0;
    while (at < parent.end) {
        if (count == out.len) return null;
        out[count] = element(bytes, at, parent.end) orelse return null;
        at = out[count].end;
        count += 1;
    }
    return out[0..count];
}

fn only_child(bytes: []const u8, parent: Span, tag: u8) ?Element {
    var one: [1]Element = undefined;
    const list = children(bytes, parent, &one) orelse return null;
    if (list.len != 1) return null;
    if (list[0].tag != tag) return null;
    return list[0];
}

/// A Name of one commonName in a UTF8String: its value.
fn common_name(bytes: []const u8, name: Element) ?Span {
    if (name.tag != 0x30) return null;
    const set = only_child(bytes, name.value, 0x31) orelse return null;
    const pair = only_child(bytes, set.value, 0x30) orelse return null;
    var two: [2]Element = undefined;
    const list = children(bytes, pair.value, &two) orelse return null;
    if (list.len != 2) return null;
    if (!std.mem.eql(u8, list[0].value.of(bytes), &.{ 0x55, 0x04, 0x03 })) return null;
    if (list[1].tag != 0x0C) return null;
    if (list[1].value.len() == 0) return null;
    if (list[1].value.len() > constants.x509_cn_bytes_max) return null;
    return list[1].value;
}

/// Milliseconds of a time, by plain arithmetic that tolerates any day number; the round trip
/// through the writer refuses what the calendar does not have.
fn time_ms(bytes: []const u8, time: Element) ?u64 {
    const text = time.value.of(bytes);
    var year: u64 = 0;
    var rest: []const u8 = undefined;
    if (time.tag == 0x17 and text.len == 13) {
        const short = number(text[0..2]) orelse return null;
        year = if (short < 50) 2000 + short else 1900 + short;
        rest = text[2..];
    } else if (time.tag == 0x18 and text.len == 15) {
        year = number(text[0..4]) orelse return null;
        rest = text[4..];
    } else return null;
    if (year < 1970) return null;
    if (rest[10] != 'Z') return null;
    const month = number(rest[0..2]) orelse return null;
    if (month < 1 or month > 12) return null;
    const day = number(rest[2..4]) orelse return null;
    if (day < 1) return null;
    var days: u64 = 0;
    var y: u64 = 1970;
    while (y < year) : (y += 1) days += if (leap(y)) 366 else 365;
    const lengths = [_]u64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    for (lengths[0 .. month - 1], 1..) |length, m| {
        days += length + @intFromBool(m == 2 and leap(year));
    }
    days += day - 1;
    const hour = number(rest[4..6]) orelse return null;
    const minute = number(rest[6..8]) orelse return null;
    const second = number(rest[8..10]) orelse return null;
    const seconds = (days * 24 + hour) * 60 * 60 + minute * 60 + second;
    if (seconds > 253_402_300_799) return null; // 9999-12-31T23:59:59Z, the writer's limit
    return seconds * 1000;
}

fn leap(year: u64) bool {
    if (year % 400 == 0) return true;
    if (year % 100 == 0) return false;
    return year % 4 == 0;
}

fn number(text: []const u8) ?u64 {
    var value: u64 = 0;
    for (text) |byte| {
        if (byte < '0' or byte > '9') return null;
        value = value * 10 + byte - '0';
    }
    return value;
}

/// A positive INTEGER in the fewest bytes, not zero, at most the cluster's serial length.
fn serial_ok(content: []const u8) bool {
    if (content.len == 0 or content.len > constants.x509_serial_bytes_max) return false;
    if (content[0] & 0x80 != 0) return false;
    if (content.len > 1 and content[0] == 0 and content[1] & 0x80 == 0) return false;
    const magnitude = if (content[0] == 0) content[1..] else content;
    if (magnitude.len == 0) return false;
    for (magnitude) |byte| {
        if (byte != 0) return true;
    }
    return false;
}

/// The naive decode, or `null` when the oracle refuses.
pub fn decode(bytes: []const u8) ?Verdict {
    if (bytes.len > constants.x509_cert_bytes_max) return null;
    const limit: u32 = @intCast(bytes.len);
    const certificate = element(bytes, 0, limit) orelse return null;
    if (certificate.tag != 0x30 or certificate.end != limit) return null;
    var top: [3]Element = undefined;
    const outer = children(bytes, certificate.value, &top) orelse return null;
    if (outer.len != 3 or outer[0].tag != 0x30) return null;
    if (outer[2].tag != 0x03 or outer[2].value.len() != 65) return null;
    var fields: [8]Element = undefined;
    const tbs = children(bytes, outer[0].value, &fields) orelse return null;
    if (tbs.len != 8 or tbs[7].tag != 0xA3) return null;
    var parsed: x509.Parsed = undefined;
    parsed.profile = .cluster;
    parsed.tbs = .{ .start = 0, .end = outer[0].end }; // reencode does not read it.
    parsed.signature = .{ .start = outer[2].value.start + 1, .end = outer[2].value.end };
    if (tbs[1].tag != 0x02 or !serial_ok(tbs[1].value.of(bytes))) return null;
    parsed.serial = tbs[1].value;
    parsed.issuer_cn = common_name(bytes, tbs[3]) orelse return null;
    parsed.subject_cn = common_name(bytes, tbs[5]) orelse return null;
    var times: [2]Element = undefined;
    const validity = children(bytes, tbs[4].value, &times) orelse return null;
    if (tbs[4].tag != 0x30 or validity.len != 2) return null;
    parsed.not_before_ms = time_ms(bytes, validity[0]) orelse return null;
    parsed.not_after_ms = time_ms(bytes, validity[1]) orelse return null;
    var key_parts: [2]Element = undefined;
    const key = children(bytes, tbs[6].value, &key_parts) orelse return null;
    if (key.len != 2 or key[1].tag != 0x03 or key[1].value.len() != 33) return null;
    parsed.public_key = .{ .start = key[1].value.start + 1, .end = key[1].value.end };
    if (!extensions(bytes, tbs[7], &parsed)) return null;
    if (!meaning_ok(bytes, &parsed)) return null;
    var again: x509.Der = .{};
    x509.reencode(&again, bytes, &parsed) catch return null;
    if (!std.mem.eql(u8, again.slice(), bytes)) return null;
    return .{
        .kind = parsed.kind,
        .not_before_ms = parsed.not_before_ms,
        .not_after_ms = parsed.not_after_ms,
        .name = parsed.name,
    };
}

/// The kind from the number of extensions and the SAN (a DNS name, or the path of a URI), the
/// name from the SAN, the identity from the last.
fn extensions(bytes: []const u8, wrapper: Element, parsed: *x509.Parsed) bool {
    const list = only_child(bytes, wrapper.value, 0x30) orelse return false;
    var items: [5]Element = undefined;
    const all = children(bytes, list.value, &items) orelse return false;
    parsed.name = .{ .start = 0, .end = 0 };
    parsed.identity = .{ .start = 0, .end = 0 };
    if (all.len == 2) {
        parsed.kind = .ca;
        return true;
    }
    if (all.len != 4 and all.len != 5) return false;
    const san = extension_value(bytes, all[3]) orelse return false;
    const general = only_child(bytes, san, 0x30) orelse return false;
    var names: [1]Element = undefined;
    const name_list = children(bytes, general.value, &names) orelse return false;
    if (name_list.len != 1) return false;
    parsed.name = name_list[0].value;
    parsed.kind = switch (name_list[0].tag) {
        0x82 => .server,
        0x86 => uri_kind(parsed.name.of(bytes)) orelse return false,
        else => return false,
    };
    const with_identity = parsed.kind == .workload or parsed.kind == .client;
    if (all.len != @as(usize, if (with_identity) 5 else 4)) return false;
    if (with_identity) {
        const value = extension_value(bytes, all[4]) orelse return false;
        if (parsed.kind == .workload) {
            _ = identity_mod.decode(value.of(bytes)) catch return false;
        } else {
            _ = identity_mod.decode_client(value.of(bytes)) catch return false;
        }
        parsed.identity = value;
    }
    return true;
}

/// The kind a SPIFFE URI's first path segment names, by plain text: `spiffe://<cluster>/<path>/`.
fn uri_kind(uri: []const u8) ?x509.Kind {
    const prefix = "spiffe://";
    if (uri.len < prefix.len or !std.mem.eql(u8, uri[0..prefix.len], prefix)) return null;
    const rest = uri[prefix.len..];
    const first = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const after = rest[first + 1 ..];
    const second = std.mem.indexOfScalar(u8, after, '/') orelse return null;
    const segment = after[0..second];
    if (std.mem.eql(u8, segment, "service")) return .workload;
    if (std.mem.eql(u8, segment, "node")) return .node;
    if (std.mem.eql(u8, segment, "client")) return .client;
    return null;
}

/// The OCTET STRING of an extension: its last child.
fn extension_value(bytes: []const u8, item: Element) ?Span {
    var parts: [3]Element = undefined;
    const list = children(bytes, item.value, &parts) orelse return null;
    if (list.len < 2) return null;
    const last = list[list.len - 1];
    if (last.tag != 0x04) return null;
    return last.value;
}

/// The checks the round trip cannot make: names, and the lifetime against the kind's bound.
fn meaning_ok(bytes: []const u8, parsed: *const x509.Parsed) bool {
    const issuer = parsed.issuer_cn.of(bytes);
    const subject = parsed.subject_cn.of(bytes);
    const name = parsed.name.of(bytes);
    if (issuer.len != x509.ca_cn_bytes) return false;
    if (!std.mem.startsWith(u8, issuer, x509.ca_cn_prefix)) return false;
    for (issuer[x509.ca_cn_prefix.len..]) |byte| {
        if (std.mem.indexOfScalar(u8, "0123456789abcdef", byte) == null) return false;
    }
    switch (parsed.kind) {
        .ca => if (!std.mem.eql(u8, issuer, subject)) return false,
        .workload, .node, .client => {
            const spiffe = identity_mod.spiffe_parse(name) catch return false;
            if (!std.mem.eql(u8, spiffe.name, subject)) return false;
        },
        .server => {
            if (identity_mod.dns_problem(name, constants.x509_dns_name_bytes_max)) return false;
            if (!std.mem.eql(u8, name, subject)) return false;
        },
    }
    if (parsed.not_after_ms <= parsed.not_before_ms) return false;
    const bound = switch (parsed.kind) {
        .ca => constants.x509_ca_ttl_ms_max,
        .workload, .server, .node, .client => constants.x509_leaf_ttl_ms_max,
    };
    return parsed.not_after_ms - parsed.not_before_ms <= bound;
}
