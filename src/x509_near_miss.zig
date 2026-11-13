//! The near-miss table for `x509.zig`: each row is a good certificate with exactly one edit, and
//! the refusal the edit must get from `parse`. A row passes only when the error is the named one,
//! so a parser that refused for the wrong reason, or accepted, fails. Parse comes before the
//! signature check, so the edited certificates keep the original signature. No file, clock or
//! environment: runs under WASI too.

const std = @import("std");
const x509 = @import("x509.zig");
const der = @import("x509_der.zig");
const t = @import("x509_test.zig");

const testing = std.testing;

const Kind = x509.Kind;
const Slice = []const u8;

/// A certificate cut into the pieces an edit replaces. `tbs` holds the TBSCertificate's children
/// before the extensions, `ext` the extensions, each a whole TLV.
const Parts = struct {
    tbs: [12]Slice = undefined,
    tbs_n: u32 = 0,
    ext: [12]Slice = undefined,
    ext_n: u32 = 0,
    has_ext: bool = true,
    alg: Slice = undefined,
    sig: Slice = undefined,

    fn push_tbs(parts: *Parts, piece: Slice) void {
        parts.tbs[parts.tbs_n] = piece;
        parts.tbs_n += 1;
    }

    fn push_ext(parts: *Parts, piece: Slice) void {
        parts.ext[parts.ext_n] = piece;
        parts.ext_n += 1;
    }

    fn drop_ext(parts: *Parts, index: usize) void {
        std.mem.copyForwards(
            Slice,
            parts.ext[index .. parts.ext_n - 1],
            parts.ext[index + 1 .. parts.ext_n],
        );
        parts.ext_n -= 1;
    }

    fn drop_tbs(parts: *Parts, index: usize) void {
        std.mem.copyForwards(
            Slice,
            parts.tbs[index .. parts.tbs_n - 1],
            parts.tbs[index + 1 .. parts.tbs_n],
        );
        parts.tbs_n -= 1;
    }
};

fn whole(bytes: Slice, span: der.Span) Slice {
    return bytes[span.start..span.end];
}

fn split(bytes: Slice) !Parts {
    var parts: Parts = .{};
    var top = der.Reader.init(bytes, .{ .start = 0, .end = @intCast(bytes.len) });
    const certificate = try top.expect(der.tag_sequence);
    var outer = der.Reader.init(bytes, certificate.value);
    const tbs = try outer.expect(der.tag_sequence);
    parts.alg = whole(bytes, (try outer.next()).whole);
    parts.sig = whole(bytes, (try outer.next()).whole);
    var inner = der.Reader.init(bytes, tbs.value);
    while (!inner.finished()) {
        const element = try inner.next();
        if (element.tag != 0xA3) {
            parts.push_tbs(whole(bytes, element.whole));
            continue;
        }
        var wrapper = der.Reader.init(bytes, element.value);
        const list = try wrapper.expect(der.tag_sequence);
        var extensions = der.Reader.init(bytes, list.value);
        while (!extensions.finished()) parts.push_ext(whole(bytes, (try extensions.next()).whole));
    }
    return parts;
}

fn assemble(buffer: []u8, parts: *const Parts) ![]const u8 {
    var writer = der.Writer.init(buffer);
    const outer = writer.mark();
    try writer.prepend(parts.sig);
    try writer.prepend(parts.alg);
    const tbs = writer.mark();
    if (parts.has_ext) {
        const list = writer.mark();
        var i = parts.ext_n;
        while (i > 0) : (i -= 1) try writer.prepend(parts.ext[i - 1]);
        try writer.close(der.tag_sequence, list);
        try writer.close(0xA3, list);
    }
    var i = parts.tbs_n;
    while (i > 0) : (i -= 1) try writer.prepend(parts.tbs[i - 1]);
    try writer.close(der.tag_sequence, tbs);
    try writer.close(der.tag_sequence, outer);
    return writer.written();
}

/// Room for the literal pieces an edit makes.
const Scratch = struct {
    pieces: [4][400]u8 = undefined,
    used: u32 = 0,

    /// A TLV with `tag` and `content`, kept alive in the scratch.
    fn tlv(scratch: *Scratch, tag: u8, content: Slice) Slice {
        const buffer = &scratch.pieces[scratch.used];
        scratch.used += 1;
        var writer = der.Writer.init(buffer);
        writer.element(tag, content) catch unreachable; // The pieces are far below 400 bytes.
        return writer.written();
    }

    /// An extension: SEQUENCE { OID, [BOOLEAN critical], OCTET STRING value }.
    fn extension(scratch: *Scratch, oid: Slice, critical: ?Slice, value: Slice) Slice {
        const buffer = &scratch.pieces[scratch.used];
        scratch.used += 1;
        var writer = der.Writer.init(buffer);
        const start = writer.mark();
        writer.element(der.tag_octet_string, value) catch unreachable; // Small, as above.
        if (critical) |flag| writer.element(der.tag_boolean, flag) catch unreachable; // Small.
        writer.element(der.tag_oid, oid) catch unreachable; // Small.
        writer.close(der.tag_sequence, start) catch unreachable; // Small.
        return writer.written();
    }

    /// A Name: SEQUENCE { SET { SEQUENCE { commonName, string } } } with the given string tag.
    fn name(scratch: *Scratch, string_tag: u8, text: Slice) Slice {
        const buffer = &scratch.pieces[scratch.used];
        scratch.used += 1;
        var writer = der.Writer.init(buffer);
        const start = writer.mark();
        writer.element(string_tag, text) catch unreachable; // Small.
        writer.element(der.tag_oid, &.{ 0x55, 0x04, 0x03 }) catch unreachable; // Small.
        writer.close(der.tag_sequence, start) catch unreachable; // Small.
        writer.close(der.tag_set, start) catch unreachable; // Small.
        writer.close(der.tag_sequence, start) catch unreachable; // Small.
        return writer.written();
    }
};

const oid_san = [_]u8{ 0x55, 0x1D, 0x11 };
const oid_basic = [_]u8{ 0x55, 0x1D, 0x13 };

const Mutate = *const fn (*Parts, *Scratch) void;

const Row = struct {
    name: []const u8,
    kind: Kind,
    mutate: Mutate,
    expect: x509.Error,
};

fn certificate_of(kind: Kind, out: *x509.Der) !void {
    switch (kind) {
        .ca => try t.make_ca(out),
        .workload => try t.make_workload(out),
        .server => try t.make_server(out),
        .node => try t.make_node(out),
        .client => try t.make_client(out),
    }
}

// ---- The edits. Each one is a function so that the table below reads as a table. -------------

fn no_version(parts: *Parts, _: *Scratch) void {
    parts.drop_tbs(0);
}
fn version_four(parts: *Parts, _: *Scratch) void {
    parts.tbs[0] = &.{ 0xA0, 0x03, 0x02, 0x01, 0x03 };
}
fn serial_negative(parts: *Parts, _: *Scratch) void {
    var serial: [18]u8 = @splat(0x11);
    serial[0..3].* = .{ 0x02, 0x10, 0x80 };
    parts.tbs[1] = &serial;
}
fn serial_empty(parts: *Parts, _: *Scratch) void {
    parts.tbs[1] = &.{ 0x02, 0x00 };
}
fn serial_padded(parts: *Parts, _: *Scratch) void {
    parts.tbs[1] = &.{ 0x02, 0x03, 0x00, 0x40, 0x01 };
}
fn serial_long(parts: *Parts, scratch: *Scratch) void {
    const content: [17]u8 = @splat(0x41);
    parts.tbs[1] = scratch.tlv(der.tag_integer, &content);
}
fn alg_null(parts: *Parts, _: *Scratch) void {
    parts.tbs[2] = &.{ 0x30, 0x07, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x05, 0x00 };
}
fn alg_other(parts: *Parts, _: *Scratch) void {
    parts.tbs[2] = &.{ 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x71 };
}
fn alg_outer_other(parts: *Parts, _: *Scratch) void {
    parts.alg = &.{ 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x71 };
}
fn serial_padded_17(parts: *Parts, scratch: *Scratch) void {
    var content: [17]u8 = @splat(0xC1);
    content[0] = 0x00;
    parts.tbs[1] = scratch.tlv(der.tag_integer, &content);
}
fn serial_zero(parts: *Parts, _: *Scratch) void {
    parts.tbs[1] = &.{ 0x02, 0x01, 0x00 };
}
/// RFC 5280: issuerUniqueID [1] and subjectUniqueID [2] are IMPLICIT BIT STRINGs, so primitive.
fn issuer_unique_id(parts: *Parts, _: *Scratch) void {
    parts.push_tbs(&.{ 0x81, 0x02, 0x00, 0xAA });
}
fn subject_unique_id(parts: *Parts, _: *Scratch) void {
    parts.push_tbs(&.{ 0x82, 0x02, 0x00, 0xAA });
}
/// notBefore as a GeneralizedTime in 2023, a year UTCTime reaches: not the canonical form.
fn validity_generalized(parts: *Parts, scratch: *Scratch) void {
    var content: [40]u8 = undefined;
    const before = scratch.tlv(der.tag_generalized_time, "20231114211320Z");
    const after = scratch.tlv(der.tag_utc_time, "231114231320Z");
    @memcpy(content[0..before.len], before);
    @memcpy(content[before.len..][0..after.len], after);
    parts.tbs[4] = scratch.tlv(der.tag_sequence, content[0 .. before.len + after.len]);
}
const oid_key_usage = [_]u8{ 0x55, 0x1D, 0x0F };
const oid_ext_key_usage = [_]u8{ 0x55, 0x1D, 0x25 };
const eku_server = [_]u8{
    0x30, 0x0A, 0x06, 0x08, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01,
};
fn eku_code_signing(parts: *Parts, scratch: *Scratch) void {
    const code_signing = [_]u8{
        0x30, 0x0A, 0x06, 0x08, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x03,
    };
    parts.ext[2] = scratch.extension(&oid_ext_key_usage, &.{0xFF}, &code_signing);
}
fn eku_not_critical(parts: *Parts, scratch: *Scratch) void {
    parts.ext[2] = scratch.extension(&oid_ext_key_usage, null, &eku_server);
}
fn ku_extra_bits(parts: *Parts, scratch: *Scratch) void {
    // digitalSignature and keyEncipherment.
    parts.ext[1] = scratch.extension(&oid_key_usage, &.{0xFF}, &.{ 0x03, 0x02, 0x05, 0xA0 });
}
fn ku_not_critical(parts: *Parts, scratch: *Scratch) void {
    parts.ext[1] = scratch.extension(&oid_key_usage, null, &.{ 0x03, 0x02, 0x07, 0x80 });
}
fn san_two_uris(parts: *Parts, scratch: *Scratch) void {
    var content: [90]u8 = undefined;
    const first = scratch.tlv(0x86, "spiffe://prod.example/service/broker-1");
    const second = scratch.tlv(0x86, "spiffe://prod.example/service/broker-2");
    @memcpy(content[0..first.len], first);
    @memcpy(content[first.len..][0..second.len], second);
    const value = scratch.tlv(der.tag_sequence, content[0 .. first.len + second.len]);
    parts.ext[3] = scratch.extension(&oid_san, null, value);
}
fn san_job_path(parts: *Parts, scratch: *Scratch) void {
    const uri = "spiffe://prod.example/job/broker-1";
    const value = scratch.tlv(der.tag_sequence, scratch.tlv(0x86, uri));
    parts.ext[3] = scratch.extension(&oid_san, null, value);
}
fn swap_first_two(parts: *Parts, _: *Scratch) void {
    std.mem.swap(Slice, &parts.ext[0], &parts.ext[1]);
}
fn duplicate_first(parts: *Parts, _: *Scratch) void {
    std.mem.copyBackwards(Slice, parts.ext[1 .. parts.ext_n + 1], parts.ext[0..parts.ext_n]);
    parts.ext_n += 1;
}
fn unknown_critical(parts: *Parts, scratch: *Scratch) void {
    parts.push_ext(scratch.extension(&.{ 0x2A, 0x03, 0x04 }, &.{0xFF}, &.{}));
}
fn unknown_plain(parts: *Parts, scratch: *Scratch) void {
    parts.push_ext(scratch.extension(&.{ 0x2A, 0x03, 0x04 }, null, &.{}));
}
fn no_extensions(parts: *Parts, _: *Scratch) void {
    parts.has_ext = false;
}
fn drop_last_extension(parts: *Parts, _: *Scratch) void {
    parts.drop_ext(parts.ext_n - 1);
}
fn basic_false_written(parts: *Parts, scratch: *Scratch) void {
    const value = scratch.tlv(der.tag_sequence, &.{ 0x01, 0x01, 0x00 });
    parts.ext[0] = scratch.extension(&oid_basic, &.{0xFF}, value[0..]);
}
fn basic_true_as_one(parts: *Parts, scratch: *Scratch) void {
    const value = scratch.tlv(der.tag_sequence, &.{ 0x01, 0x01, 0x01, 0x02, 0x01, 0x00 });
    parts.ext[0] = scratch.extension(&oid_basic, &.{0xFF}, value);
}
fn basic_not_critical(parts: *Parts, scratch: *Scratch) void {
    parts.ext[0] = scratch.extension(&oid_basic, null, &.{ 0x30, 0x00 });
}
fn basic_pathlen_one(parts: *Parts, scratch: *Scratch) void {
    const value = scratch.tlv(der.tag_sequence, &.{ 0x01, 0x01, 0xFF, 0x02, 0x01, 0x01 });
    parts.ext[0] = scratch.extension(&oid_basic, &.{0xFF}, value);
}
fn san_critical(parts: *Parts, scratch: *Scratch) void {
    const value = scratch.tlv(der.tag_sequence, scratch.tlv(0x82, "broker.botpike.com"));
    parts.ext[3] = scratch.extension(&oid_san, &.{0xFF}, value);
}
fn san_two_names(parts: *Parts, scratch: *Scratch) void {
    var content: [60]u8 = undefined;
    const first = scratch.tlv(0x82, "broker.botpike.com");
    const second = scratch.tlv(0x82, "other.botpike.com");
    @memcpy(content[0..first.len], first);
    @memcpy(content[first.len..][0..second.len], second);
    const value = scratch.tlv(der.tag_sequence, content[0 .. first.len + second.len]);
    parts.ext[3] = scratch.extension(&oid_san, null, value);
}
fn san_uri_on_server(parts: *Parts, scratch: *Scratch) void {
    const uri = scratch.tlv(0x86, "spiffe://prod.example/service/x");
    const value = scratch.tlv(der.tag_sequence, uri);
    parts.ext[3] = scratch.extension(&oid_san, null, value);
}
fn san_wildcard(parts: *Parts, scratch: *Scratch) void {
    const value = scratch.tlv(der.tag_sequence, scratch.tlv(0x82, "*.botpike.com"));
    parts.ext[3] = scratch.extension(&oid_san, null, value);
}
fn san_dns_on_workload(parts: *Parts, scratch: *Scratch) void {
    const value = scratch.tlv(der.tag_sequence, scratch.tlv(0x82, "broker-1.botpike.com"));
    parts.ext[3] = scratch.extension(&oid_san, null, value);
}
fn san_bad_path(parts: *Parts, scratch: *Scratch) void {
    const uri = scratch.tlv(0x86, "spiffe://prod.example/service/");
    const value = scratch.tlv(der.tag_sequence, uri);
    parts.ext[3] = scratch.extension(&oid_san, null, value);
}
fn san_other_service(parts: *Parts, scratch: *Scratch) void {
    const value = scratch.tlv(
        der.tag_sequence,
        scratch.tlv(0x86, "spiffe://prod.example/service/other"),
    );
    parts.ext[3] = scratch.extension(&oid_san, null, value);
}
fn subject_printable(parts: *Parts, scratch: *Scratch) void {
    parts.tbs[5] = scratch.name(0x13, "broker-1");
}
fn subject_empty(parts: *Parts, scratch: *Scratch) void {
    parts.tbs[5] = scratch.name(der.tag_utf8_string, "");
}
fn issuer_bad_form(parts: *Parts, scratch: *Scratch) void {
    parts.tbs[3] = scratch.name(der.tag_utf8_string, "zcube-ca-nothex");
}
fn subject_two_rdns(parts: *Parts, scratch: *Scratch) void {
    var content: [60]u8 = undefined;
    const one = scratch.name(der.tag_utf8_string, "broker-1");
    // A Name with the same RDN twice: the content of one name, repeated.
    const inner = one[2..];
    @memcpy(content[0..inner.len], inner);
    @memcpy(content[inner.len..][0..inner.len], inner);
    parts.tbs[5] = scratch.tlv(der.tag_sequence, content[0 .. 2 * inner.len]);
}
fn key_short(parts: *Parts, scratch: *Scratch) void {
    var content: [32]u8 = @splat(0x22);
    content[0] = 0;
    const algorithm: Slice = &.{ 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70 };
    const key = scratch.tlv(der.tag_bit_string, content[0..32]);
    var info: [60]u8 = undefined;
    @memcpy(info[0..algorithm.len], algorithm);
    @memcpy(info[algorithm.len..][0..key.len], key);
    parts.tbs[6] = scratch.tlv(der.tag_sequence, info[0 .. algorithm.len + key.len]);
}
fn sig_unused_bits(parts: *Parts, scratch: *Scratch) void {
    var content: [65]u8 = @splat(0x33);
    content[0] = 1;
    parts.sig = scratch.tlv(der.tag_bit_string, &content);
}
fn sig_short(parts: *Parts, scratch: *Scratch) void {
    var content: [64]u8 = @splat(0x33);
    content[0] = 0;
    parts.sig = scratch.tlv(der.tag_bit_string, &content);
}
fn add_identity_from_workload(parts: *Parts, scratch: *Scratch) void {
    _ = scratch;
    var other: x509.Der = .{};
    t.make_workload(&other) catch unreachable; // A fixed, valid request.
    const donor = split(other.slice()) catch unreachable; // The writer's own output.
    parts.push_ext(donor.ext[4]);
}
fn add_eku(parts: *Parts, scratch: *Scratch) void {
    const client_auth = [_]u8{
        0x30, 0x0A, 0x06, 0x08, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x02,
    };
    parts.push_ext(scratch.extension(&.{ 0x55, 0x1D, 0x25 }, null, &client_auth));
}

/// Extension `index` of a good certificate of `kind`, copied into the scratch.
fn donor_extension(scratch: *Scratch, kind: Kind, index: usize) Slice {
    var other: x509.Der = .{};
    certificate_of(kind, &other) catch unreachable; // A fixed, valid request.
    const parts = split(other.slice()) catch unreachable; // The writer's own output.
    const piece = parts.ext[index];
    const buffer = &scratch.pieces[scratch.used];
    scratch.used += 1;
    @memcpy(buffer[0..piece.len], piece);
    return buffer[0..piece.len];
}
fn san_uri(parts: *Parts, scratch: *Scratch, uri: Slice) void {
    const value = scratch.tlv(der.tag_sequence, scratch.tlv(0x86, uri));
    parts.ext[3] = scratch.extension(&oid_san, null, value);
}
fn node_add_identity(parts: *Parts, scratch: *Scratch) void {
    parts.push_ext(donor_extension(scratch, .workload, 4));
}
fn node_add_client_identity(parts: *Parts, scratch: *Scratch) void {
    parts.push_ext(donor_extension(scratch, .client, 4));
}
fn client_workload_identity(parts: *Parts, scratch: *Scratch) void {
    parts.ext[4] = donor_extension(scratch, .workload, 4);
}
fn workload_client_identity(parts: *Parts, scratch: *Scratch) void {
    parts.ext[4] = donor_extension(scratch, .client, 4);
}
fn client_scope_three(parts: *Parts, scratch: *Scratch) void {
    const piece = donor_extension(scratch, .client, 4);
    const bytes: []u8 = @constCast(piece);
    // The extension ends with the ENUMERATED scope's one content byte.
    std.debug.assert(bytes[bytes.len - 3] == der.tag_enumerated);
    bytes[bytes.len - 1] = 3;
    parts.ext[4] = piece;
}
fn client_scope_zero(parts: *Parts, scratch: *Scratch) void {
    const piece = donor_extension(scratch, .client, 4);
    const bytes: []u8 = @constCast(piece);
    std.debug.assert(bytes[bytes.len - 3] == der.tag_enumerated);
    bytes[bytes.len - 1] = 0;
    parts.ext[4] = piece;
}
fn client_version_one(parts: *Parts, scratch: *Scratch) void {
    const piece = donor_extension(scratch, .client, 4);
    const bytes: []u8 = @constCast(piece);
    // SEQUENCE { INTEGER 2, ENUMERATED s }: the version's content byte is sixth from the end.
    std.debug.assert(bytes[bytes.len - 6] == der.tag_integer);
    bytes[bytes.len - 4] = 1;
    parts.ext[4] = piece;
}
fn node_with_server_eku(parts: *Parts, scratch: *Scratch) void {
    parts.ext[2] = donor_extension(scratch, .server, 2);
}
fn node_other_name(parts: *Parts, scratch: *Scratch) void {
    san_uri(parts, scratch, "spiffe://prod.example/node/node-2");
}
fn node_bad_name(parts: *Parts, scratch: *Scratch) void {
    san_uri(parts, scratch, "spiffe://prod.example/node/Node_1");
}
fn node_as_client(parts: *Parts, scratch: *Scratch) void {
    san_uri(parts, scratch, "spiffe://prod.example/client/node-1");
}
fn node_as_service(parts: *Parts, scratch: *Scratch) void {
    san_uri(parts, scratch, "spiffe://prod.example/service/node-1");
}
fn node_dns(parts: *Parts, scratch: *Scratch) void {
    const value = scratch.tlv(der.tag_sequence, scratch.tlv(0x82, "node-1.botpike.com"));
    parts.ext[3] = scratch.extension(&oid_san, null, value);
}
fn client_other_name(parts: *Parts, scratch: *Scratch) void {
    san_uri(parts, scratch, "spiffe://prod.example/client/ops-2");
}
fn client_as_node(parts: *Parts, scratch: *Scratch) void {
    san_uri(parts, scratch, "spiffe://prod.example/node/ops-1");
}
fn client_as_service(parts: *Parts, scratch: *Scratch) void {
    san_uri(parts, scratch, "spiffe://prod.example/service/ops-1");
}
fn client_empty_name(parts: *Parts, scratch: *Scratch) void {
    san_uri(parts, scratch, "spiffe://prod.example/client/");
}

fn row(name: []const u8, kind: Kind, mutate: Mutate, expect: x509.Error) Row {
    return .{ .name = name, .kind = kind, .mutate = mutate, .expect = expect };
}

const rows = [_]Row{
    row("no version", .workload, no_version, error.BadVersion),
    row("version 4", .workload, version_four, error.BadVersion),
    row("serial negative", .workload, serial_negative, error.BadSerial),
    row("serial empty", .workload, serial_empty, error.BadSerial),
    row("serial padded", .workload, serial_padded, error.BadSerial),
    row("serial 17 bytes", .workload, serial_long, error.BadSerial),
    row("serial padded to 17", .workload, serial_padded_17, error.BadSerial),
    row("serial zero", .workload, serial_zero, error.BadSerial),
    row("not before generalized in 2023", .workload, validity_generalized, error.BadTime),
    row("alg null params", .workload, alg_null, error.BadAlgorithm),
    row("alg other oid", .workload, alg_other, error.BadAlgorithm),
    row("alg copies differ", .workload, alg_outer_other, error.BadAlgorithm),
    row("issuer unique id", .workload, issuer_unique_id, error.UniqueId),
    row("subject unique id", .workload, subject_unique_id, error.UniqueId),
    row("extensions swapped", .workload, swap_first_two, error.UnexpectedExtension),
    row("extension twice", .workload, duplicate_first, error.DuplicateExtension),
    row("unknown critical", .workload, unknown_critical, error.UnknownCritical),
    row("unknown plain", .workload, unknown_plain, error.UnexpectedExtension),
    row("no extensions", .workload, no_extensions, error.MissingExtension),
    row("no identity", .workload, drop_last_extension, error.MissingExtension),
    row("no server name", .server, drop_last_extension, error.MissingExtension),
    row("basic with explicit false", .workload, basic_false_written, error.BadExtension),
    row("basic true as 01", .ca, basic_true_as_one, error.BadExtension),
    row("basic not critical", .ca, basic_not_critical, error.BadExtension),
    row("path length one", .ca, basic_pathlen_one, error.BadExtension),
    row("san critical", .server, san_critical, error.BadExtension),
    row("san two names", .server, san_two_names, error.BadSan),
    row("san uri on server", .server, san_uri_on_server, error.BadSan),
    row("san wildcard", .server, san_wildcard, error.BadSan),
    row("san dns on workload", .workload, san_dns_on_workload, error.BadSan),
    row("san bad path", .workload, san_bad_path, error.BadSan),
    row("san other service", .workload, san_other_service, error.BadName),
    row("san two uris", .workload, san_two_uris, error.BadSan),
    row("san job path", .workload, san_job_path, error.BadSan),
    row("eku code signing", .server, eku_code_signing, error.BadExtension),
    row("eku not critical", .server, eku_not_critical, error.BadExtension),
    row("ku extra bits", .server, ku_extra_bits, error.BadExtension),
    row("ku not critical", .workload, ku_not_critical, error.BadExtension),
    row("subject printable", .workload, subject_printable, error.BadName),
    row("subject empty", .workload, subject_empty, error.BadName),
    row("issuer bad form", .workload, issuer_bad_form, error.BadName),
    row("subject two rdns", .workload, subject_two_rdns, error.BadName),
    row("key 31 bytes", .workload, key_short, error.Malformed),
    row("signature unused bits", .workload, sig_unused_bits, error.Malformed),
    row("signature 63 bytes", .workload, sig_short, error.Malformed),
    row("server with identity", .server, add_identity_from_workload, error.UnexpectedExtension),
    row("ca with eku", .ca, add_eku, error.UnexpectedExtension),
    row("node with identity", .node, node_add_identity, error.UnexpectedExtension),
    row("node with scope", .node, node_add_client_identity, error.UnexpectedExtension),
    row("node with server eku", .node, node_with_server_eku, error.BadSan),
    row("node other name", .node, node_other_name, error.BadName),
    row("node bad name", .node, node_bad_name, error.BadSan),
    row("node as client", .node, node_as_client, error.MissingExtension),
    row("node as service", .node, node_as_service, error.MissingExtension),
    row("node dns name", .node, node_dns, error.BadSan),
    row("client no scope", .client, drop_last_extension, error.MissingExtension),
    row("client workload identity", .client, client_workload_identity, error.BadIdentity),
    row("client scope 3", .client, client_scope_three, error.BadIdentity),
    row("client scope 0", .client, client_scope_zero, error.BadIdentity),
    row("client version 1", .client, client_version_one, error.BadIdentity),
    row("client other name", .client, client_other_name, error.BadName),
    row("client as node", .client, client_as_node, error.UnexpectedExtension),
    row("client as service", .client, client_as_service, error.BadIdentity),
    row("client empty name", .client, client_empty_name, error.BadSan),
    row("client dns name", .client, node_dns, error.BadSan),
    row("workload with scope", .workload, workload_client_identity, error.BadIdentity),
};

test "each near-miss certificate is refused for its own reason" {
    // Goal: the accepted set is exactly the writer's output set, and each refusal is the right
    // one. Method: split a good certificate, make one edit, put it back together with the old
    // signature and check `parse`'s error against the row.
    var failures: usize = 0;
    inline for (rows) |entry| {
        var certificate: x509.Der = .{};
        try certificate_of(entry.kind, &certificate);
        _ = try x509.parse(certificate.slice());
        var parts = try split(certificate.slice());
        var scratch: Scratch = .{};
        entry.mutate(&parts, &scratch);
        var buffer: [1100]u8 = undefined;
        const edited = try assemble(&buffer, &parts);
        if (x509.parse(edited)) |_| {
            std.debug.print("near miss accepted: {s}\n", .{entry.name});
            failures += 1;
        } else |err| {
            if (err != entry.expect) {
                std.debug.print(
                    "near miss {s}: got {t}, want {t}\n",
                    .{ entry.name, err, entry.expect },
                );
                failures += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

/// Replaces the first occurrence of `needle` by `with` (same length) in a copy of a certificate.
fn patched(certificate: *x509.Der, needle: Slice, with: Slice) !x509.Der {
    var copy = certificate.*;
    const bytes = copy.bytes[copy.start..];
    const at = std.mem.indexOf(u8, bytes, needle) orelse return error.NeedleMissing;
    @memcpy(bytes[at..][0..with.len], with);
    return copy;
}

const Patch = struct { name: []const u8, needle: Slice, with: Slice, expect: x509.Error };

const not_before = "231114211320Z";
const not_after = "231114231320Z";

fn patch(name: []const u8, needle: Slice, with: Slice, expect: x509.Error) Patch {
    return .{ .name = name, .needle = needle, .with = with, .expect = expect };
}

const patches = [_]Patch{
    patch("month 13", not_before, "231314211320Z", error.BadTime),
    patch("february 30", not_before, "230230211320Z", error.BadTime),
    patch("second 60", not_before, "231114211360Z", error.BadTime),
    patch("no Z", not_before, "231114211320X", error.BadTime),
    patch("hour 24", not_before, "231114241320Z", error.BadTime),
    patch("ends before start", not_after, "231114201320Z", error.BadValidity),
    patch("ends at start", not_after, "231114211320Z", error.BadValidity),
    patch("37 days", not_after, "231221231320Z", error.LifetimeTooLong),
    patch("other service in the name", "broker-1", "broker-2", error.BadName),
};

test "same-length edits of a workload certificate are refused for their own reason" {
    // Goal: the time fields and the name check refuse what is out of range. Method: patch one
    // field in place (the length does not change, so no re-encoding) and check the error.
    var certificate: x509.Der = .{};
    try t.make_workload(&certificate);
    for (patches) |entry| {
        const edited = try patched(&certificate, entry.needle, entry.with);
        try testing.expectError(entry.expect, x509.parse(edited.slice()));
    }
}

test "DER-level damage to a certificate is refused" {
    // Goal: trailing bytes, cut-off, indefinite and non-minimal lengths, and oversize input never
    // parse. Method: edit the outer encoding of a good certificate.
    var certificate: x509.Der = .{};
    try t.make_workload(&certificate);
    const bytes = certificate.slice();
    var longer: [1100]u8 = @splat(0);
    @memcpy(longer[0..bytes.len], bytes);
    try testing.expectError(error.Malformed, x509.parse(longer[0 .. bytes.len + 1]));
    try testing.expectError(error.Malformed, x509.parse(bytes[0 .. bytes.len - 1]));
    try testing.expectError(error.Malformed, x509.parse(bytes[0..4]));
    try testing.expectError(error.Malformed, x509.parse(&.{}));
    var indefinite = longer;
    indefinite[1] = 0x80;
    try testing.expectError(error.Malformed, x509.parse(indefinite[0..bytes.len]));
    try testing.expectError(error.TooLarge, x509.parse(longer[0..1100]));
    // A one-byte length written in the long form is not minimal.
    var padded: [1100]u8 = undefined;
    padded[0] = 0x30;
    padded[1] = 0x83;
    padded[2] = 0x00;
    padded[3] = @intCast(bytes.len - 4 >> 8);
    padded[4] = @intCast((bytes.len - 4) & 0xFF);
    @memcpy(padded[5 .. bytes.len + 1], bytes[4..]);
    try testing.expectError(error.Malformed, x509.parse(padded[0 .. bytes.len + 1]));
}
