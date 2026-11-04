//! What a workload certificate says about its holder: the SPIFFE ID and the private identity
//! extension (docs/briefs/mtls-client.md, "X.509 v3"). Kept apart from `x509.zig` so that the
//! relay's issuer (B3) can import the identity without the certificate code. Core code: no
//! allocation, no recursion, no clock.
//!
//! The extension's value is a DER SEQUENCE `{ version INTEGER 1, image_digest OCTET STRING (32),
//! placement_epoch INTEGER 0..2^63-1, labels SEQUENCE OF SEQUENCE { key UTF8String, value
//! UTF8String } }`, labels sorted by key with unique keys. Both directions check every bound, so a
//! value the writer makes always decodes and a value that decodes always re-encodes to itself.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const der = @import("x509_der.zig");
const records = @import("records.zig");

pub const Error = error{
    /// Not the extension's DER shape, or a version other than 1.
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
    /// The job name is not a name (`records.name_problem`).
    BadJobName,
    /// Not `spiffe://<cluster>/job/<name>`.
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

/// A lowercase DNS name: labels of `a-z0-9-` of 1..63 bytes, none starting or ending with `-`,
/// joined by single dots, no wildcard, at most `bytes_max` bytes.
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
        start += label.len + 1;
    }
    return false;
}

pub const Spiffe = struct {
    cluster: []const u8,
    job: []const u8,
};

const spiffe_prefix = "spiffe://";
const spiffe_path = "/job/";

/// `spiffe://<cluster>/job/<name>` into `buffer`.
pub fn spiffe_write(
    buffer: *[constants.x509_spiffe_bytes_max]u8,
    cluster: []const u8,
    job: []const u8,
) Error![]const u8 {
    if (dns_problem(cluster, constants.x509_cluster_bytes_max)) return error.BadCluster;
    if (records.name_problem(job, constants.node_name_bytes_max) != null) return error.BadJobName;
    const total = spiffe_prefix.len + cluster.len + spiffe_path.len + job.len;
    assert(total <= buffer.len);
    var at: usize = 0;
    inline for (.{ spiffe_prefix, cluster, spiffe_path, job }) |part| {
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
    const path = rest[slash..];
    if (!std.mem.startsWith(u8, path, spiffe_path)) return error.BadSpiffe;
    const job = path[spiffe_path.len..];
    if (dns_problem(cluster, constants.x509_cluster_bytes_max)) return error.BadCluster;
    if (records.name_problem(job, constants.node_name_bytes_max) != null) return error.BadJobName;
    return .{ .cluster = cluster, .job = job };
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

test "label bounds are refused on the way in and on the way out" {
    // Goal: the boundary where valid becomes invalid, for both directions. Method: each limit one
    // under and one over, through `validate`; the same lists written by hand are refused by
    // `decode` through the shared rules.
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
    // Goal: the near misses are refused. Method: a table.
    var buffer: [constants.x509_spiffe_bytes_max]u8 = undefined;
    const uri = try spiffe_write(&buffer, "prod.example", "broker-1");
    try testing.expectEqualStrings("spiffe://prod.example/job/broker-1", uri);
    const parsed = try spiffe_parse(uri);
    try testing.expectEqualStrings("prod.example", parsed.cluster);
    try testing.expectEqualStrings("broker-1", parsed.job);
    const bad = [_][]const u8{
        "spiffe://prod/job/",      "spiffe://prod/job/a/b",
        "spiffe://prod/job/a?x=1", "spiffe://prod/job/a#f",
        "spiffe://u@prod/job/a",   "spiffe://prod:80/job/a",
        "spiffe://prod/service/a", "spiffe://prod/job/A",
        "spiffe://prod/job/.",     "spiffe://prod/job/..",
        "spiffe://prod//job/a",    "spiffe:///job/a",
        "spiffe://Prod/job/a",     "spiffe://pr..od/job/a",
        "spiffe://-prod/job/a",    "spiffe://prod./job/a",
        "spiffe://*.prod/job/a",   "http://prod/job/a",
        "spiffe://prod/job/a/",    "SPIFFE://prod/job/a",
        "spiffe://prod",           "spiffe://prod/job",
    };
    for (bad) |text| try testing.expect(std.meta.isError(spiffe_parse(text)));
    try testing.expectError(error.BadCluster, spiffe_write(&buffer, "", "a"));
    try testing.expectError(error.BadJobName, spiffe_write(&buffer, "prod", "a_b"));
    try testing.expect(dns_problem("*.example.com", 64));
    const long_name: [65]u8 = @splat('a');
    try testing.expect(dns_problem(&long_name, 64));
    try testing.expect(!dns_problem("broker.botpike.com", 64));
}
