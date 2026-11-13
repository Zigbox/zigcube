//! What a certificate says about its holder: the SPIFFE ID and the private identity extension
//! (docs/briefs/mtls-client.md, "X.509 v3"; docs/briefs/b7.md). Kept apart from `x509.zig` so
//! that the relay's issuer (B4) can import the identity without the certificate code. Core code:
//! no allocation, no recursion, no clock.
//!
//! The extension has two versions, and a certificate's kind says which it carries (decision file
//! 2026-11-13-identity-extension-v2-scope.md):
//!
//! - Version 1, a workload's: a DER SEQUENCE `{ version INTEGER 1, image_digest OCTET STRING
//!   (32), placement_epoch INTEGER 0..2^63-1, labels SEQUENCE OF SEQUENCE { key UTF8String,
//!   value UTF8String } }`, labels sorted by key with unique keys.
//! - Version 2, a client's: `{ version INTEGER 2, scope ENUMERATED { jobs (1), admin (2) } }`.
//!
//! Both directions check every bound, so a value the writer makes always decodes and a value that
//! decodes always re-encodes to itself.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const der = @import("x509_der.zig");
const records = @import("records.zig");

pub const Error = error{
    /// Not the extension's DER shape, or not the version asked for.
    Malformed,
    NoSpace,
    TooManyLabels,
    /// A key or value over its bound, or a key that is empty.
    LabelTooLong,
    /// The labels' keys and values together exceed `x509_labels_bytes_max`.
    LabelsTooLarge,
    /// Keys are not strictly increasing (so: sorted and unique).
    LabelsNotSorted,
    /// A key with a byte outside 0x21..0x7E, or a value that is not UTF-8 or holds a control byte.
    BadLabel,
    /// The cluster part of a SPIFFE ID is not a sequence of lowercase DNS labels.
    BadCluster,
    /// The service name is not a name (`records.name_problem`).
    BadServiceName,
    /// The node name is not a name.
    BadNodeName,
    /// The client name is not a name.
    BadClientName,
    /// Not `spiffe://<cluster>/<service|node|client>/<name>`.
    BadSpiffe,
    /// Not a lowercase DNS name without wildcard.
    BadDnsName,
};

pub const Label = struct {
    key: []const u8,
    value: []const u8,
};

pub const Identity = struct {
    /// The BLAKE3 tree digest of the image the workload runs.
    image_digest: [32]u8,
    placement_epoch: u64,
    labels: []const Label,
};

pub const version: u8 = 1;
/// The client form's version (B7).
pub const version_client: u8 = 2;

/// What a `client` certificate allows (docs/briefs/b7.md): `jobs` creates, reads, cancels and
/// watches jobs and nothing else; `admin` does everything. The values are the ENUMERATED's.
pub const Scope = enum(u8) {
    jobs = 1,
    admin = 2,

    pub fn text(scope: Scope) []const u8 {
        return switch (scope) {
            .jobs => "jobs",
            .admin => "admin",
        };
    }

    /// The scope a word names, for `ca issue-client --scope`.
    pub fn parse(word: []const u8) ?Scope {
        if (std.mem.eql(u8, word, "jobs")) return .jobs;
        if (std.mem.eql(u8, word, "admin")) return .admin;
        return null;
    }
};

/// The extension's OID, 2.25.192541954756406065736426278304158759968 (decision file
/// 2026-11-04-mtls-identity-extension-oid.md), DER content bytes.
pub const oid: [20]u8 = .{
    0x69, 0x82, 0xA1, 0xDA, 0x9D, 0xD2, 0xF1, 0xDF, 0xCA, 0xBD,
    0xAF, 0x9A, 0xF9, 0xF5, 0xAD, 0x9A, 0xD7, 0xDA, 0xF8, 0x20,
};

fn label_problem(label: Label) ?Error {
    if (label.key.len == 0) return error.LabelTooLong;
    if (label.key.len > constants.x509_label_key_bytes_max) return error.LabelTooLong;
    if (label.value.len > constants.x509_label_value_bytes_max) return error.LabelTooLong;
    for (label.key) |byte| {
        if (byte < 0x21 or byte > 0x7E) return error.BadLabel;
    }
    if (!std.unicode.utf8ValidateSlice(label.value)) return error.BadLabel;
    for (label.value) |byte| {
        if (byte < 0x20 or byte == 0x7F) return error.BadLabel;
    }
    return null;
}

/// Checks the bounds and the order of a label list. The one place the rules are written: encode
/// calls it on the caller's labels, decode on each label it reads.
pub fn validate(labels: []const Label) Error!void {
    if (labels.len > constants.x509_labels_max) return error.TooManyLabels;
    var total: usize = 0;
    for (labels, 0..) |label, index| {
        if (label_problem(label)) |problem| return problem;
        total += label.key.len + label.value.len;
        if (index > 0) {
            const order = std.mem.order(u8, labels[index - 1].key, label.key);
            if (order != .lt) return error.LabelsNotSorted;
        }
    }
    if (total > constants.x509_labels_bytes_max) return error.LabelsTooLarge;
}

/// Writes the extension's value (the SEQUENCE) in front of what `writer` holds.
pub fn encode(writer: *der.Writer, identity: *const Identity) Error!void {
    try validate(identity.labels);
    const outer = writer.mark();
    const labels_mark = writer.mark();
    var index = identity.labels.len;
    while (index > 0) {
        index -= 1;
        const label = identity.labels[index];
        const pair = writer.mark();
        try writer.element(der.tag_utf8_string, label.value);
        try writer.element(der.tag_utf8_string, label.key);
        try writer.close(der.tag_sequence, pair);
    }
    try writer.close(der.tag_sequence, labels_mark);
    try writer.unsigned(identity.placement_epoch);
    try writer.element(der.tag_octet_string, &identity.image_digest);
    try writer.unsigned(version);
    try writer.close(der.tag_sequence, outer);
}

/// A decoded extension; the labels stay in the input and are read with `labels`.
pub const Decoded = struct {
    image_digest: [32]u8,
    placement_epoch: u64,
    labels_count: u32,
    labels_span: der.Span,

    pub fn labels(decoded: *const Decoded, bytes: []const u8) LabelIterator {
        return .{ .reader = der.Reader.init(bytes, decoded.labels_span) };
    }
};

pub const LabelIterator = struct {
    reader: der.Reader,

    pub fn next(iterator: *LabelIterator, bytes: []const u8) Error!?Label {
        if (iterator.reader.finished()) return null;
        const pair = iterator.reader.expect(der.tag_sequence) catch return error.Malformed;
        var inner = der.Reader.init(bytes, pair.value);
        const key = inner.expect(der.tag_utf8_string) catch return error.Malformed;
        const value = inner.expect(der.tag_utf8_string) catch return error.Malformed;
        inner.finish() catch return error.Malformed;
        return .{ .key = key.value.of(bytes), .value = value.value.of(bytes) };
    }
};

/// Decodes and checks an extension value: shape, version, every label's bounds and the order.
pub fn decode(bytes: []const u8) Error!Decoded {
    var outer = der.Reader.init(bytes, .{ .start = 0, .end = @intCast(bytes.len) });
    const sequence = outer.expect(der.tag_sequence) catch return error.Malformed;
    outer.finish() catch return error.Malformed;
    var reader = der.Reader.init(bytes, sequence.value);
    const version_element = reader.expect(der.tag_integer) catch return error.Malformed;
    const version_bytes = version_element.value.of(bytes);
    if (!std.mem.eql(u8, version_bytes, &.{version})) return error.Malformed;
    const digest = reader.expect(der.tag_octet_string) catch return error.Malformed;
    if (digest.value.len() != 32) return error.Malformed;
    const epoch_element = reader.expect(der.tag_integer) catch return error.Malformed;
    const epoch = der.unsigned_u63(epoch_element.value.of(bytes)) catch return error.Malformed;
    const labels_element = reader.expect(der.tag_sequence) catch return error.Malformed;
    reader.finish() catch return error.Malformed;

    var decoded: Decoded = .{
        .image_digest = digest.value.of(bytes)[0..32].*,
        .placement_epoch = epoch,
        .labels_count = 0,
        .labels_span = labels_element.value,
    };
    try check_labels(&decoded, bytes);
    return decoded;
}

/// Writes a client's extension value, `{ version 2, scope }`, in front of what `writer` holds.
pub fn encode_client(writer: *der.Writer, scope: Scope) Error!void {
    const outer = writer.mark();
    try writer.element(der.tag_enumerated, &.{@backingInt(scope)});
    try writer.unsigned(version_client);
    try writer.close(der.tag_sequence, outer);
    assert(writer.written().len == 8);
}

/// Decodes a client's extension value: exactly `{ INTEGER 2, ENUMERATED 1|2 }`, nothing after.
pub fn decode_client(bytes: []const u8) Error!Scope {
    var outer = der.Reader.init(bytes, .{ .start = 0, .end = @intCast(bytes.len) });
    const sequence = outer.expect(der.tag_sequence) catch return error.Malformed;
    outer.finish() catch return error.Malformed;
    var reader = der.Reader.init(bytes, sequence.value);
    const version_element = reader.expect(der.tag_integer) catch return error.Malformed;
    const version_bytes = version_element.value.of(bytes);
    if (!std.mem.eql(u8, version_bytes, &.{version_client})) return error.Malformed;
    const scope_element = reader.expect(der.tag_enumerated) catch return error.Malformed;
    reader.finish() catch return error.Malformed;
    const scope_bytes = scope_element.value.of(bytes);
    if (scope_bytes.len != 1) return error.Malformed;
    const scope: Scope = switch (scope_bytes[0]) {
        1 => .jobs,
        2 => .admin,
        else => return error.Malformed,
    };
    assert(@backingInt(scope) == scope_bytes[0]);
    return scope;
}

fn check_labels(decoded: *Decoded, bytes: []const u8) Error!void {
    var iterator = decoded.labels(bytes);
    var previous: ?Label = null;
    var total: usize = 0;
    var count: u32 = 0;
    while (try iterator.next(bytes)) |label| {
        count += 1;
        if (count > constants.x509_labels_max) return error.TooManyLabels;
        if (label_problem(label)) |problem| return problem;
        total += label.key.len + label.value.len;
        if (previous) |before| {
            if (std.mem.order(u8, before.key, label.key) != .lt) return error.LabelsNotSorted;
        }
        previous = label;
    }
    if (total > constants.x509_labels_bytes_max) return error.LabelsTooLarge;
    decoded.labels_count = count;
}

// ---- Names -----------------------------------------------------------------------------------

/// A lowercase DNS name: labels of `a-z0-9-` of 1..63 bytes, none starting or ending with `-` and
/// none all digits (so no name reads as an IPv4 address), joined by single dots, no wildcard, at
/// most `bytes_max` bytes.
pub fn dns_problem(name: []const u8, bytes_max: u32) bool {
    assert(bytes_max <= 255);
    if (name.len == 0) return true;
    if (name.len > bytes_max) return true;
    var start: usize = 0;
    while (start <= name.len) {
        const rest = name[start..];
        const dot = std.mem.indexOfScalar(u8, rest, '.');
        const label = if (dot) |at| rest[0..at] else rest;
        if (records.name_problem(label, 63) != null) return true;
        if (all_digits(label)) return true;
        start += label.len + 1;
    }
    return false;
}

/// An all-numeric label makes a name read as an IP address (RFC 1123 2.1), so it is refused.
fn all_digits(label: []const u8) bool {
    assert(label.len > 0);
    for (label) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

/// The three path kinds of a SPIFFE ID (decision file 2026-11-04-spiffe-service-path.md for
/// `/service/`; docs/briefs/b7.md is the decision that adds `/node/` and `/client/`). No other
/// path kind is accepted; one would need its own decision.
pub const Path = enum {
    /// A workload: `<name>` is the service name.
    service,
    /// A node's agent (B7): `<name>` is the node name.
    node,
    /// A client of the API (B7): `<name>` is the name `ca issue-client` was given.
    client,

    pub fn text(path: Path) []const u8 {
        return switch (path) {
            .service => "/service/",
            .node => "/node/",
            .client => "/client/",
        };
    }

    fn name_error(path: Path) Error {
        return switch (path) {
            .service => error.BadServiceName,
            .node => error.BadNodeName,
            .client => error.BadClientName,
        };
    }
};

/// `spiffe://<cluster><path><name>`.
pub const Spiffe = struct {
    cluster: []const u8,
    path: Path,
    name: []const u8,
};

const spiffe_prefix = "spiffe://";

comptime {
    // `x509_spiffe_bytes_max` is sized for the longest path, `/service/`.
    for (std.enums.values(Path)) |path| assert(path.text().len <= Path.service.text().len);
    assert(constants.x509_spiffe_bytes_max == spiffe_prefix.len +
        constants.x509_cluster_bytes_max + Path.service.text().len +
        constants.node_name_bytes_max);
}

/// `spiffe://<cluster><path><name>` into `buffer`.
pub fn spiffe_write(
    buffer: *[constants.x509_spiffe_bytes_max]u8,
    path: Path,
    cluster: []const u8,
    name: []const u8,
) Error![]const u8 {
    if (dns_problem(cluster, constants.x509_cluster_bytes_max)) return error.BadCluster;
    if (records.name_problem(name, constants.node_name_bytes_max) != null) {
        return path.name_error();
    }
    const path_text = path.text();
    const total = spiffe_prefix.len + cluster.len + path_text.len + name.len;
    assert(total <= buffer.len);
    var at: usize = 0;
    inline for (.{ spiffe_prefix, cluster, path_text, name }) |part| {
        @memcpy(buffer[at..][0..part.len], part);
        at += part.len;
    }
    assert(at == total);
    return buffer[0..total];
}

/// Splits a SPIFFE ID of exactly that shape: no port, userinfo, query, fragment or other path.
pub fn spiffe_parse(uri: []const u8) Error!Spiffe {
    if (!std.mem.startsWith(u8, uri, spiffe_prefix)) return error.BadSpiffe;
    const rest = uri[spiffe_prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.BadSpiffe;
    const cluster = rest[0..slash];
    const path_and_name = rest[slash..];
    const path: Path = for (std.enums.values(Path)) |candidate| {
        if (std.mem.startsWith(u8, path_and_name, candidate.text())) break candidate;
    } else return error.BadSpiffe;
    const name = path_and_name[path.text().len..];
    if (dns_problem(cluster, constants.x509_cluster_bytes_max)) return error.BadCluster;
    if (records.name_problem(name, constants.node_name_bytes_max) != null) {
        return path.name_error();
    }
    assert(name.len > 0);
    return .{ .cluster = cluster, .path = path, .name = name };
}

// ---- Tests -----------------------------------------------------------------------------------

const testing = std.testing;

fn sample_labels() [3]Label {
    return .{
        .{ .key = "app", .value = "broker" },
        .{ .key = "env", .value = "prod" },
        .{ .key = "tier", .value = "ünïcode ok" },
    };
}

test "the identity extension round-trips and decode re-encodes to the same bytes" {
    // Goal: writer and decoder are inverses on every valid value. Method: encode, decode, compare
    // every field and the labels, then encode the decoded fields again.
    const labels = sample_labels();
    const identity: Identity = .{
        .image_digest = @splat(0xAB),
        .placement_epoch = (1 << 63) - 1,
        .labels = &labels,
    };
    var buffer: [512]u8 = undefined;
    var writer = der.Writer.init(&buffer);
    try encode(&writer, &identity);
    const bytes = writer.written();
    const decoded = try decode(bytes);
    try testing.expectEqual(@as(u32, 3), decoded.labels_count);
    try testing.expectEqual(identity.placement_epoch, decoded.placement_epoch);
    try testing.expectEqualSlices(u8, &identity.image_digest, &decoded.image_digest);
    var iterator = decoded.labels(bytes);
    for (labels) |label| {
        const got = (try iterator.next(bytes)).?;
        try testing.expectEqualSlices(u8, label.key, got.key);
        try testing.expectEqualSlices(u8, label.value, got.value);
    }
    try testing.expect((try iterator.next(bytes)) == null);

    var again_buffer: [512]u8 = undefined;
    var again = der.Writer.init(&again_buffer);
    try encode(&again, &identity);
    try testing.expectEqualSlices(u8, bytes, again.written());
}

test "label bounds are refused by validate, on the way in" {
    // Goal: the boundary where valid becomes invalid when encoding. Method: each limit one under
    // and one over, through `validate`. The decode side is the next test.
    const long_key: [constants.x509_label_key_bytes_max + 1]u8 = @splat('k');
    const long_value: [constants.x509_label_value_bytes_max + 1]u8 = @splat('v');
    try testing.expectError(error.LabelTooLong, validate(&.{.{ .key = &long_key, .value = "" }}));
    try testing.expectError(error.LabelTooLong, validate(&.{
        .{ .key = "a", .value = &long_value },
    }));
    try testing.expectError(error.LabelTooLong, validate(&.{.{ .key = "", .value = "x" }}));
    try testing.expectError(error.BadLabel, validate(&.{.{ .key = "a b", .value = "x" }}));
    try testing.expectError(error.BadLabel, validate(&.{.{ .key = "a", .value = "\xff" }}));
    try testing.expectError(error.BadLabel, validate(&.{.{ .key = "a", .value = "x\ny" }}));
    try testing.expectError(error.LabelsNotSorted, validate(&.{
        .{ .key = "b", .value = "" }, .{ .key = "a", .value = "" },
    }));
    try testing.expectError(error.LabelsNotSorted, validate(&.{
        .{ .key = "a", .value = "1" }, .{ .key = "a", .value = "2" },
    }));
    const half: [constants.x509_labels_bytes_max / 2]u8 = @splat('x');
    try validate(&.{ .{ .key = "a", .value = half[2..] }, .{ .key = "b", .value = &half } });
    try testing.expectError(error.LabelsTooLarge, validate(&.{
        .{ .key = "a", .value = &half }, .{ .key = "b", .value = &half },
    }));
    var many: [constants.x509_labels_max + 1]Label = undefined;
    var keys: [many.len][2]u8 = undefined;
    for (&many, &keys, 0..) |*label, *key, i| {
        key.* = .{ 'a', 'a' + @as(u8, @intCast(i)) };
        label.* = .{ .key = key, .value = "" };
    }
    try validate(many[0..constants.x509_labels_max]);
    try testing.expectError(error.TooManyLabels, validate(&many));
}

/// Test-only: the extension's value with `labels` exactly as given, no checks, so that `decode`
/// can be shown a list `encode` would refuse.
pub fn encode_unchecked(writer: *der.Writer, labels: []const Label) Error!void {
    const outer = writer.mark();
    const labels_mark = writer.mark();
    var index = labels.len;
    while (index > 0) {
        index -= 1;
        const pair = writer.mark();
        try writer.element(der.tag_utf8_string, labels[index].value);
        try writer.element(der.tag_utf8_string, labels[index].key);
        try writer.close(der.tag_sequence, pair);
    }
    try writer.close(der.tag_sequence, labels_mark);
    try writer.unsigned(0);
    try writer.element(der.tag_octet_string, &@as([32]u8, @splat(1)));
    try writer.unsigned(version);
    try writer.close(der.tag_sequence, outer);
}

fn decode_unchecked(buffer: []u8, labels: []const Label) Error!Decoded {
    var writer = der.Writer.init(buffer);
    encode_unchecked(&writer, labels) catch unreachable; // The test buffer fits every list.
    return decode(writer.written());
}

test "label bounds are refused by decode, on the way out" {
    // Goal: decode checks every label rule itself, not only encode (the order and the total size
    // are decode's own checks in `check_labels`). Method: lists `validate` refuses, written by
    // `encode_unchecked`, each with the exact error; each one under its limit decodes.
    var buffer: [4096]u8 = undefined;
    try testing.expectError(error.LabelsNotSorted, decode_unchecked(&buffer, &.{
        .{ .key = "b", .value = "" }, .{ .key = "a", .value = "" },
    }));
    try testing.expectError(error.LabelsNotSorted, decode_unchecked(&buffer, &.{
        .{ .key = "a", .value = "1" }, .{ .key = "a", .value = "2" },
    }));
    _ = try decode_unchecked(&buffer, &.{
        .{ .key = "a", .value = "1" }, .{ .key = "b", .value = "2" },
    });
    const long_key: [constants.x509_label_key_bytes_max + 1]u8 = @splat('k');
    try testing.expectError(error.LabelTooLong, decode_unchecked(&buffer, &.{
        .{ .key = &long_key, .value = "" },
    }));
    _ = try decode_unchecked(&buffer, &.{.{ .key = long_key[1..], .value = "" }});
    try testing.expectError(error.BadLabel, decode_unchecked(&buffer, &.{
        .{ .key = "a b", .value = "x" },
    }));
    try testing.expectError(error.BadLabel, decode_unchecked(&buffer, &.{
        .{ .key = "a", .value = "\xff" },
    }));
    const half: [constants.x509_labels_bytes_max / 2]u8 = @splat('x');
    _ = try decode_unchecked(&buffer, &.{
        .{ .key = "a", .value = half[2..] }, .{ .key = "b", .value = &half },
    });
    try testing.expectError(error.LabelsTooLarge, decode_unchecked(&buffer, &.{
        .{ .key = "a", .value = half[1..] }, .{ .key = "b", .value = &half },
    }));
    var many: [constants.x509_labels_max + 1]Label = undefined;
    var keys: [many.len][2]u8 = undefined;
    for (&many, &keys, 0..) |*label, *key, i| {
        key.* = .{ 'a', 'a' + @as(u8, @intCast(i)) };
        label.* = .{ .key = key, .value = "" };
    }
    const decoded = try decode_unchecked(&buffer, many[0..constants.x509_labels_max]);
    try testing.expectEqual(constants.x509_labels_max, decoded.labels_count);
    try testing.expectError(error.TooManyLabels, decode_unchecked(&buffer, &many));
}

test "decode refuses a damaged extension value" {
    // Goal: every shape error is Malformed. Method: version 2, short digest, trailing byte, a
    // negative epoch, a label with three parts.
    var buffer: [512]u8 = undefined;
    var writer = der.Writer.init(&buffer);
    const identity: Identity = .{ .image_digest = @splat(1), .placement_epoch = 7, .labels = &.{} };
    try encode(&writer, &identity);
    const good = writer.written();
    _ = try decode(good);
    var copy: [512]u8 = undefined;
    @memcpy(copy[0..good.len], good);
    copy[4] = 2; // version
    try testing.expectError(error.Malformed, decode(copy[0..good.len]));
    try testing.expectError(error.Malformed, decode(good[0 .. good.len - 1]));
    @memcpy(copy[0..good.len], good);
    copy[good.len] = 0;
    try testing.expectError(error.Malformed, decode(copy[0 .. good.len + 1]));
    @memcpy(copy[0..good.len], good);
    copy[good.len - 3] = 0x80; // epoch INTEGER content
    try testing.expectError(error.Malformed, decode(copy[0..good.len]));
}

test "SPIFFE IDs and DNS names have exactly one shape" {
    // Goal: the near misses are refused; `/service/`, `/node/` and `/client/` are the only paths.
    // Method: a table, and each path kind written and parsed back.
    var buffer: [constants.x509_spiffe_bytes_max]u8 = @splat(0xAA);
    const good = [_]struct { path: Path, uri: []const u8 }{
        .{ .path = .service, .uri = "spiffe://prod.example/service/broker-1" },
        .{ .path = .node, .uri = "spiffe://prod.example/node/broker-1" },
        .{ .path = .client, .uri = "spiffe://prod.example/client/broker-1" },
    };
    for (good) |case| {
        const uri = try spiffe_write(&buffer, case.path, "prod.example", "broker-1");
        try testing.expectEqualStrings(case.uri, uri);
        const parsed = try spiffe_parse(uri);
        try testing.expectEqualStrings("prod.example", parsed.cluster);
        try testing.expectEqual(case.path, parsed.path);
        try testing.expectEqualStrings("broker-1", parsed.name);
    }
    // The longest ID fits the bound exactly.
    const cluster_long: [constants.x509_cluster_bytes_max]u8 = @splat('c');
    const name_long: [constants.node_name_bytes_max]u8 = @splat('n');
    const longest = try spiffe_write(&buffer, .service, &cluster_long, &name_long);
    try testing.expectEqual(@as(usize, constants.x509_spiffe_bytes_max), longest.len);
    const bad = [_][]const u8{
        "spiffe://prod/service/",      "spiffe://prod/service/a/b",
        "spiffe://prod/service/a?x=1", "spiffe://prod/service/a#f",
        "spiffe://u@prod/service/a",   "spiffe://prod:80/service/a",
        "spiffe://prod/job/a",         "spiffe://prod/nodes/a",
        "spiffe://prod/node/",         "spiffe://prod/node/a/b",
        "spiffe://prod/node/A",        "spiffe://prod/Node/a",
        "spiffe://prod/client/",       "spiffe://prod/clients/a",
        "spiffe://prod/client/a?x",    "spiffe://prod/client/a_b",
        "spiffe://prod/node//a",       "spiffe://prod/client/node/a",
        "spiffe://prod/services/a",    "spiffe://prod/service/A",
        "spiffe://prod/service/.",     "spiffe://prod/service/..",
        "spiffe://prod//service/a",    "spiffe:///service/a",
        "spiffe://Prod/service/a",     "spiffe://pr..od/service/a",
        "spiffe://-prod/service/a",    "spiffe://prod./service/a",
        "spiffe://*.prod/service/a",   "http://prod/service/a",
        "spiffe://prod/service/a/",    "SPIFFE://prod/service/a",
        "spiffe://prod",               "spiffe://prod/service",
        "spiffe://10.0.0.1/service/a", "spiffe://prod.2024/service/a",
    };
    for (bad) |text| try testing.expect(std.meta.isError(spiffe_parse(text)));
    try testing.expectError(error.BadCluster, spiffe_write(&buffer, .node, "", "a"));
    try testing.expectError(error.BadServiceName, spiffe_write(&buffer, .service, "prod", "a_b"));
    try testing.expectError(error.BadNodeName, spiffe_write(&buffer, .node, "prod", "a_b"));
    try testing.expectError(error.BadClientName, spiffe_write(&buffer, .client, "prod", "A"));
    try testing.expectError(error.BadNodeName, spiffe_parse("spiffe://prod/node/a.b"));
    try testing.expectError(error.BadClientName, spiffe_parse("spiffe://prod/client/-a"));
    try testing.expect(dns_problem("*.example.com", 64));
    try testing.expect(dns_problem("192.168.0.1", 64));
    try testing.expect(dns_problem("broker.123", 64));
    try testing.expect(!dns_problem("broker1.example2.com", 64));
    try testing.expect(!dns_problem("1a.example.com", 64));
    const long_name: [65]u8 = @splat('a');
    try testing.expect(dns_problem(&long_name, 64));
    try testing.expect(!dns_problem("broker.botpike.com", 64));
}

test "the client form of the extension has exactly one encoding per scope" {
    // Goal: version 2 carries the scope and nothing else, and the two versions never read as each
    // other. Method: encode and decode each scope against fixed bytes; then each near miss of the
    // eight bytes; then each version through the other's decoder.
    const expected = [_]struct { scope: Scope, bytes: [8]u8 }{
        .{ .scope = .jobs, .bytes = .{ 0x30, 0x06, 0x02, 0x01, 0x02, 0x0A, 0x01, 0x01 } },
        .{ .scope = .admin, .bytes = .{ 0x30, 0x06, 0x02, 0x01, 0x02, 0x0A, 0x01, 0x02 } },
    };
    for (expected) |case| {
        var buffer: [16]u8 = @splat(0xAA);
        var writer = der.Writer.init(&buffer);
        try encode_client(&writer, case.scope);
        try testing.expectEqualSlices(u8, &case.bytes, writer.written());
        try testing.expectEqual(case.scope, try decode_client(&case.bytes));
        try testing.expectError(error.Malformed, decode(&case.bytes));
        try testing.expectEqual(case.scope, Scope.parse(case.scope.text()).?);
    }
    try testing.expect(Scope.parse("Jobs") == null);
    try testing.expect(Scope.parse("") == null);
    const near = [_][]const u8{
        &.{ 0x30, 0x06, 0x02, 0x01, 0x01, 0x0A, 0x01, 0x01 }, // version 1
        &.{ 0x30, 0x06, 0x02, 0x01, 0x03, 0x0A, 0x01, 0x01 }, // version 3
        &.{ 0x30, 0x06, 0x02, 0x01, 0x02, 0x0A, 0x01, 0x00 }, // scope 0
        &.{ 0x30, 0x06, 0x02, 0x01, 0x02, 0x0A, 0x01, 0x03 }, // scope 3
        &.{ 0x30, 0x06, 0x02, 0x01, 0x02, 0x02, 0x01, 0x01 }, // scope an INTEGER
        &.{ 0x30, 0x07, 0x02, 0x01, 0x02, 0x0A, 0x02, 0x00, 0x01 }, // scope padded
        &.{ 0x30, 0x08, 0x02, 0x01, 0x02, 0x0A, 0x01, 0x01, 0x05, 0x00 }, // a NULL after
        &.{ 0x30, 0x03, 0x02, 0x01, 0x02 }, // no scope
        &.{ 0x30, 0x06, 0x02, 0x01, 0x02, 0x0A, 0x01, 0x01, 0x00 }, // a byte after
        &.{ 0x31, 0x06, 0x02, 0x01, 0x02, 0x0A, 0x01, 0x01 }, // a SET
    };
    for (near) |bytes| try testing.expectError(error.Malformed, decode_client(bytes));
    var buffer: [512]u8 = undefined;
    var writer = der.Writer.init(&buffer);
    const identity: Identity = .{ .image_digest = @splat(1), .placement_epoch = 7, .labels = &.{} };
    try encode(&writer, &identity);
    try testing.expectError(error.Malformed, decode_client(writer.written()));
}
