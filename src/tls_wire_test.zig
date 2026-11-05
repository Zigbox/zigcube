//! Table tests for the TLS wire parsers that take input from a server
//! (`tls_wire.zig`, docs/briefs/mtls-client.md, slice 5): every malformed shape of a
//! CertificateRequest, which the handshake tests reach only by a few examples.

const std = @import("std");
const wire = @import("tls_wire.zig");

const testing = std.testing;

/// A CertificateRequest body being built in a fixed buffer: the context, then the extensions.
const Body = struct {
    bytes: [600]u8 = undefined,
    length: u32 = 0,
    extensions_at: u32 = 0,

    fn begin(context: []const u8) Body {
        var body: Body = .{};
        body.bytes[0] = @intCast(context.len);
        @memcpy(body.bytes[1..][0..context.len], context);
        body.length = 1 + context.len + 2;
        body.extensions_at = body.length - 2;
        return body;
    }

    fn extension(body: *Body, kind: u16, data: []const u8) *Body {
        std.mem.writeInt(u16, body.bytes[body.length..][0..2], kind, .big);
        std.mem.writeInt(u16, body.bytes[body.length + 2 ..][0..2], @intCast(data.len), .big);
        @memcpy(body.bytes[body.length + 4 ..][0..data.len], data);
        body.length += 4 + data.len;
        return body;
    }

    /// A signature_algorithms-shaped extension (13, or 50 for the certificate list).
    fn schemes(body: *Body, kind: u16, list: []const u16) *Body {
        var data: [64]u8 = undefined;
        std.mem.writeInt(u16, data[0..2], @intCast(list.len * 2), .big);
        for (list, 0..) |scheme, at| std.mem.writeInt(u16, data[2 + at * 2 ..][0..2], scheme, .big);
        return body.extension(kind, data[0 .. 2 + list.len * 2]);
    }

    fn done(body: *Body) []const u8 {
        const size: u16 = @intCast(body.length - body.extensions_at - 2);
        std.mem.writeInt(u16, body.bytes[body.extensions_at..][0..2], size, .big);
        return body.bytes[0..body.length];
    }
};

const ed25519 = wire.scheme_ed25519;
const ecdsa_p256: u16 = 0x0403;

test "a CertificateRequest that can be answered, and one that cannot" {
    // Goal: the context comes back whole and `accepts_ed25519` follows both scheme lists.
    // Method: a table of well-formed requests.
    const Case = struct {
        context: []const u8,
        schemes: []const u16,
        cert: ?[]const u16,
        want: bool,
    };
    const cases = [_]Case{
        .{ .context = "", .schemes = &.{ed25519}, .cert = null, .want = true },
        .{ .context = "abc", .schemes = &.{ ecdsa_p256, ed25519 }, .cert = null, .want = true },
        .{ .context = "abc", .schemes = &.{ecdsa_p256}, .cert = null, .want = false },
        .{ .context = "", .schemes = &.{ed25519}, .cert = &.{ecdsa_p256}, .want = false },
        .{ .context = "", .schemes = &.{ed25519}, .cert = &.{ ecdsa_p256, ed25519 }, .want = true },
        .{ .context = "", .schemes = &.{ecdsa_p256}, .cert = &.{ed25519}, .want = false },
        .{
            .context = &@as([255]u8, @splat(7)),
            .schemes = &.{ed25519},
            .cert = null,
            .want = true,
        },
    };
    try expect_refusals(&cases);
}

test "a CertificateRequest skips extensions it does not use" {
    var body = Body.begin("x");
    _ = body.extension(47, &.{ 0, 5, 0, 3, 0x30, 0x01, 0x00 }).extension(0x1234, "anything");
    _ = body.schemes(13, &.{ed25519}).extension(5, &.{});
    const request = try wire.parse_certificate_request(body.done());
    try testing.expect(request.accepts_ed25519);
}

const Refusal = struct { name: []const u8, want: wire.Error, bytes: []const u8 };

fn expect_refusals(cases: []const Refusal) !void {
    for (cases) |case| {
        testing.expectError(case.want, wire.parse_certificate_request(case.bytes)) catch |err| {
            std.debug.print("case: {s}\n", .{case.name});
            return err;
        };
    }
}

test "a malformed CertificateRequest is refused with the error that names the fault" {
    // Goal: no malformed shape is read as a request. Method: each shape the review named, and
    // the shapes around it.
    var odd = Body.begin("");
    _ = odd.extension(13, &.{ 0, 3, 0x08, 0x07, 0x08 });
    var empty_list = Body.begin("");
    _ = empty_list.extension(13, &.{ 0, 0 });
    var trailing_in_extension = Body.begin("");
    _ = trailing_in_extension.extension(13, &.{ 0, 2, 0x08, 0x07, 0x00 });
    var list_past_data = Body.begin("");
    _ = list_past_data.extension(13, &.{ 0, 4, 0x08, 0x07 });
    var no_data = Body.begin("");
    _ = no_data.extension(13, &.{});
    var none = Body.begin("");
    var no_schemes = Body.begin("");
    _ = no_schemes.extension(47, &.{ 0, 0 });
    const cases = [_]Refusal{
        .{ .name = "odd scheme list", .want = error.Malformed, .bytes = odd.done() },
        .{ .name = "empty scheme list", .want = error.Malformed, .bytes = empty_list.done() },
        .{
            .name = "bytes after the list",
            .want = error.Malformed,
            .bytes = trailing_in_extension.done(),
        },
        .{
            .name = "list longer than its extension",
            .want = error.Malformed,
            .bytes = list_past_data.done(),
        },
        .{ .name = "extension with no data", .want = error.Malformed, .bytes = no_data.done() },
        .{
            .name = "no signature_algorithms",
            .want = error.MissingExtension,
            .bytes = none.done(),
        },
        .{
            .name = "only other extensions",
            .want = error.MissingExtension,
            .bytes = no_schemes.done(),
        },
    };
    for (cases) |case| {
        testing.expectError(case.want, wire.parse_certificate_request(case.bytes)) catch |err| {
            std.debug.print("case: {s}\n", .{case.name});
            return err;
        };
    }
}

test "a CertificateRequest is bounded by the message limit in every shape" {
    // Goal: no input reads past its bytes. Method: every prefix of a valid request is refused
    // or (only when it is whole) read, and never crashes.
    var body = Body.begin("ctx");
    _ = body.schemes(13, &.{ ecdsa_p256, ed25519 }).extension(47, &.{ 0, 5, 0, 3, 0x30, 1, 0 });
    const bytes = body.done();
    for (0..bytes.len) |length| {
        try testing.expectError(error.Malformed, wire.parse_certificate_request(bytes[0..length]));
    }
    _ = try wire.parse_certificate_request(bytes);
}

test "a CertificateRequest with a repeated extension or a stray byte is refused" {
    // Goal: RFC 8446 section 4.2 (no extension type twice, known or not) and the exact length of
    // the message. Method: each repeat, then a byte after the extensions and cut-short shapes.
    var duplicate = Body.begin("");
    _ = duplicate.schemes(13, &.{ed25519}).schemes(13, &.{ed25519});
    var duplicate_cert = Body.begin("");
    _ = duplicate_cert.schemes(13, &.{ed25519}).schemes(50, &.{ed25519}).schemes(50, &.{ed25519});
    var duplicate_authorities = Body.begin("");
    _ = duplicate_authorities.schemes(13, &.{ed25519}).extension(47, &.{ 0, 0 })
        .extension(47, &.{ 0, 0 });
    var duplicate_unknown = Body.begin("");
    _ = duplicate_unknown.schemes(13, &.{ed25519}).extension(0x4242, "a").extension(0x4242, "b");
    var trailing = Body.begin("");
    _ = trailing.schemes(13, &.{ed25519});
    var trailing_bytes: [64]u8 = undefined;
    const trailing_body = trailing.done();
    @memcpy(trailing_bytes[0..trailing_body.len], trailing_body);
    trailing_bytes[trailing_body.len] = 0;
    const cases = [_]Refusal{
        .{
            .name = "duplicate signature_algorithms",
            .want = error.DuplicateExtension,
            .bytes = duplicate.done(),
        },
        .{
            .name = "duplicate signature_algorithms_cert",
            .want = error.DuplicateExtension,
            .bytes = duplicate_cert.done(),
        },
        .{
            .name = "duplicate certificate_authorities",
            .want = error.DuplicateExtension,
            .bytes = duplicate_authorities.done(),
        },
        .{
            .name = "duplicate unknown extension",
            .want = error.DuplicateExtension,
            .bytes = duplicate_unknown.done(),
        },
        .{
            .name = "bytes after the extensions",
            .want = error.Malformed,
            .bytes = trailing_bytes[0 .. trailing_body.len + 1],
        },
        .{ .name = "empty body", .want = error.Malformed, .bytes = &.{} },
        .{
            .name = "context longer than the body",
            .want = error.Malformed,
            .bytes = &.{ 9, 1, 2 },
        },
        .{ .name = "no extensions length", .want = error.Malformed, .bytes = &.{ 0, 0 } },
        .{
            .name = "extensions longer than the body",
            .want = error.Malformed,
            .bytes = &.{ 0, 0, 9, 0, 13 },
        },
        .{
            .name = "extension header cut short",
            .want = error.Malformed,
            .bytes = &.{ 0, 0, 3, 0, 13, 0 },
        },
        .{
            .name = "extension data past its block",
            .want = error.Malformed,
            .bytes = &.{ 0, 0, 6, 0, 13, 0, 9, 0, 0 },
        },
    };
    try expect_refusals(&cases);
}
