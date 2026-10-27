//! Reading the API's JSON: the helpers every command shares. A reply that is JSON but lacks a
//! field the API promises is `ZC-E0103` (the client and server are different versions), never a
//! guess and never a crash.

const std = @import("std");
const assert = std.debug.assert;
const cli_http = @import("cli_http.zig");
const cli_report = @import("cli_report.zig");
const constants = @import("constants.zig");

const Allocator = std.mem.Allocator;
const Client = cli_http.Client;
const Error = cli_report.Error;
const Report = cli_report.Report;

pub const Value = std.json.Value;

pub fn member(value: Value, name: []const u8) ?Value {
    if (value != .object) return null;
    return value.object.get(name);
}

pub fn text(value: Value, name: []const u8) ?[]const u8 {
    const found = member(value, name) orelse return null;
    if (found != .string) return null;
    return found.string;
}

pub fn number(value: Value, name: []const u8) ?u64 {
    const found = member(value, name) orelse return null;
    if (found != .integer) return null;
    if (found.integer < 0) return null;
    return @intCast(found.integer);
}

pub fn array(value: Value, name: []const u8) ?[]const Value {
    const found = member(value, name) orelse return null;
    if (found != .array) return null;
    return found.array.items;
}

/// The body of a successful reply as JSON.
pub fn parse(arena: Allocator, reply: cli_http.Reply, report: *Report) Error!Value {
    return std.json.parseFromSliceLeaky(Value, arena, reply.body, .{}) catch {
        return contract(report, reply.request_id, "is not JSON");
    };
}

/// The reply is JSON the client does not understand.
pub fn contract(report: *Report, request_id: []const u8, what: []const u8) Error {
    assert(report.diag.code == null);
    report.diag.raise(.E0103);
    report.diag.while_("reading the server's answer", .{});
    report.diag.cause("the reply {s}", .{what});
    report.diag.context("reqid", "{s}", .{request_id});
    report.diag.fix(
        .{ .sentence = "use the zcube that came with the server, or upgrade the older one" },
    );
    return error.Failed;
}

pub const Kv = struct { key: []const u8, value: Value, mod_revision: u64 };

pub const Listing = struct {
    /// The store revision the first page was read at; later pages are read `at` it.
    revision: u64,
    items: []const Kv,
};

/// Every key under `prefix`, in key order, page by page at one revision.
pub fn list(arena: Allocator, client: *Client, prefix: []const u8, report: *Report) Error!Listing {
    var items: std.ArrayList(Kv) = .empty;
    var revision: u64 = 0;
    var after: ?[]const u8 = null;
    var pages: u32 = 0;
    while (pages < constants.cli_list_pages_max) : (pages += 1) {
        const path = try page_path(arena, prefix, revision, after);
        const reply = try client.get(path, report);
        const body = try parse(arena, reply, report);
        const at = number(body, "revision") orelse return contract(
            report,
            reply.request_id,
            "has no revision",
        );
        const kvs = array(body, "kvs") orelse return contract(
            report,
            reply.request_id,
            "has no kvs list",
        );
        if (pages == 0) revision = at;
        report.revision = revision;
        for (kvs) |kv| try items.append(arena, try read_kv(kv, reply.request_id, report));
        const next = member(body, "continue") orelse return contract(
            report,
            reply.request_id,
            "has no continue member",
        );
        if (next != .string) return .{ .revision = revision, .items = items.items };
        after = next.string;
    }
    return too_many(report, prefix);
}

fn read_kv(kv: Value, request_id: []const u8, report: *Report) Error!Kv {
    const key = text(kv, "key") orelse return contract(
        report,
        request_id,
        "has a key that is not text",
    );
    const value = member(kv, "value") orelse return contract(
        report,
        request_id,
        "has a key without a value",
    );
    const modified = number(kv, "mod_revision") orelse return contract(
        report,
        request_id,
        "has a key without a mod_revision",
    );
    return .{ .key = key, .value = value, .mod_revision = modified };
}

fn page_path(
    arena: Allocator,
    prefix: []const u8,
    revision: u64,
    after: ?[]const u8,
) Error![]const u8 {
    const encoded = percent_encode(arena, prefix) catch return error.OutOfMemory;
    var out: std.Io.Writer.Allocating = .init(arena);
    const writer = &out.writer;
    writer.print(
        "/v1/list?prefix={s}&limit={d}",
        .{ encoded, constants.api_list_limit_max },
    ) catch return error.OutOfMemory;
    if (after) |last| {
        const key = percent_encode(arena, last) catch return error.OutOfMemory;
        writer.print("&continue={s}&at={d}", .{ key, revision }) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn too_many(report: *Report, prefix: []const u8) Error {
    assert(report.diag.code == null);
    report.diag.raise(.E0103);
    report.diag.while_("listing {s}", .{prefix});
    report.diag.cause("more than {d} pages of keys", .{constants.cli_list_pages_max});
    report.diag.fix(.{ .sentence = "ask for one service by name" });
    return error.Failed;
}

/// Percent-encodes everything but the unreserved characters of RFC 3986.
pub fn percent_encode(arena: Allocator, input: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (input) |byte| {
        if (std.ascii.isAlphanumeric(
            byte,
        ) or byte == '-' or byte == '.' or byte == '_' or byte == '~') {
            try out.append(arena, byte);
        } else {
            try out.print(arena, "%{X:0>2}", .{byte});
        }
    }
    return out.items;
}

const testing = std.testing;

test "percent encoding keeps unreserved bytes and encodes the rest" {
    // Goal: a key in a query string. Method: a key, a space, a non-ASCII byte.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings(
        "%2Fservices%2Fhello-1",
        try percent_encode(arena, "/services/hello-1"),
    );
    try testing.expectEqualStrings("a%20b%C3%A9", try percent_encode(arena, "a b\xc3\xa9"));
    try testing.expectEqualStrings("", try percent_encode(arena, ""));
}
