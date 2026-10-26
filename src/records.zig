//! The records of docs/keys.md as Zig types, with their JSON forms and the key layout.
//!
//! Core code reads and writes the store through these and never builds a key or a value by hand,
//! so the layout of keys.md has one implementation. Every value is a JSON object with `"v": 1`;
//! a reader ignores members it does not know (a newer writer added them), and a writer omits
//! optional members it has nothing for.
//!
//! Diagnostics embedded in a record (`diagnostic`, `cause_diagnostic`) are kept as the raw JSON
//! text of DIAGNOSTICS.md (`Raw`): a controller copies them without understanding them, and the
//! readers that render one parse it with `zigbox.diagnostic.parse_json`.

const std = @import("std");
const assert = std.debug.assert;
const zigbox = @import("zigbox");
const constants = @import("constants.zig");
const codes = @import("diag/codes.zig");
const diag_mod = @import("diag.zig");
const failures = @import("store_failures.zig");
const store = @import("store.zig");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;
pub const Diagnostic = diag_mod.Diagnostic;

pub const Error = error{ Malformed, NoCapacity };

// ---- Keys ----------------------------------------------------------------------------------

/// A store key built from validated names. Fixed size, so building one cannot fail: every part
/// has a bound whose sum is under `store_key_bytes_max` (checked at compile time below).
pub const Key = struct {
    bytes: [constants.store_key_bytes_max]u8 = undefined,
    len: u32 = 0,

    pub fn slice(key: *const Key) []const u8 {
        assert(key.len > 0);
        assert(key.len <= constants.store_key_bytes_max);
        return key.bytes[0..key.len];
    }

    fn build(parts: []const []const u8) Key {
        var key: Key = .{};
        for (parts) |part| {
            assert(key.len + part.len <= constants.store_key_bytes_max);
            @memcpy(key.bytes[key.len..][0..part.len], part);
            key.len += @intCast(part.len);
        }
        if (key.slice()[key.len - 1] != '/') assert(store.key_problem(key.slice()) == null);
        return key;
    }
};

pub const prefix_services = "/services/";
pub const prefix_replicas = "/replicas/";
pub const prefix_observed = "/observed/";
pub const prefix_nodes = "/nodes/";
pub const prefix_decisions = "/decisions/";
pub const prefix_index = "/decisions-by-subject/";

pub fn service_key(name: []const u8) Key {
    assert(name_problem(name, constants.service_name_bytes_max) == null);
    return Key.build(&.{ prefix_services, name });
}

pub fn replicas_prefix(service: []const u8) Key {
    assert(name_problem(service, constants.service_name_bytes_max) == null);
    return Key.build(&.{ prefix_replicas, service, "/" });
}

pub fn replica_key(service: []const u8, id: []const u8) Key {
    assert(std.mem.startsWith(u8, id, service));
    assert(name_problem(id, constants.node_name_bytes_max) == null);
    return Key.build(&.{ prefix_replicas, service, "/", id });
}

pub fn observed_prefix(node: []const u8) Key {
    assert(name_problem(node, constants.node_name_bytes_max) == null);
    return Key.build(&.{ prefix_observed, node, "/" });
}

pub fn observed_key(node: []const u8, replica: []const u8) Key {
    assert(name_problem(replica, constants.node_name_bytes_max) == null);
    return Key.build(&.{ prefix_observed, node, "/", replica });
}

pub fn node_key(name: []const u8) Key {
    assert(name_problem(name, constants.node_name_bytes_max) == null);
    return Key.build(&.{ prefix_nodes, name });
}

pub fn decision_key(id: []const u8) Key {
    assert(id.len == decision_id_bytes);
    return Key.build(&.{ prefix_decisions, id });
}

pub fn index_prefix(kind: SubjectKind, name: []const u8) Key {
    assert(name.len > 0);
    return Key.build(&.{ prefix_index, @tagName(kind), "/", name, "/" });
}

pub fn index_key(kind: SubjectKind, name: []const u8, id: []const u8) Key {
    assert(id.len == decision_id_bytes);
    return Key.build(&.{ prefix_index, @tagName(kind), "/", name, "/", id });
}

comptime {
    // The longest key: the index entry of a replica decision.
    const longest = prefix_index.len + "service".len + 1 + constants.node_name_bytes_max + 1 +
        decision_id_bytes;
    assert(longest <= constants.store_key_bytes_max);
}

// ---- Names ---------------------------------------------------------------------------------

pub const NameProblem = enum { empty, too_long, bad_character, hyphen_at_edge };

/// Null if `name` is a hostname label of at most `bytes_max`: lowercase letters, digits and '-',
/// not starting or ending with '-' (docs/keys.md, "Names").
pub fn name_problem(name: []const u8, bytes_max: u32) ?NameProblem {
    if (name.len == 0) return .empty;
    if (name.len > bytes_max) return .too_long;
    for (name) |byte| {
        const allowed = std.ascii.isDigit(byte) or std.ascii.isLower(byte) or byte == '-';
        if (!allowed) return .bad_character;
    }
    if (name[0] == '-' or name[name.len - 1] == '-') return .hyphen_at_edge;
    return null;
}

/// `<service>-<n>`: the replica number, or null if `id` is not of that form for `service`.
pub fn replica_number(service: []const u8, id: []const u8) ?u32 {
    if (!std.mem.startsWith(u8, id, service)) return null;
    const rest = id[service.len..];
    if (rest.len < 2) return null;
    if (rest[0] != '-') return null;
    const digits = rest[1..];
    if (digits.len > 9) return null;
    for (digits) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
    }
    return std.fmt.parseInt(u32, digits, 10) catch null;
}

// ---- Records -------------------------------------------------------------------------------

/// A JSON value kept as text, already in compact form, written back as it is.
pub const Raw = struct {
    text: []const u8,

    pub fn jsonStringify(raw: Raw, jw: anytype) !void {
        assert(raw.text.len > 0);
        try jw.beginWriteRaw();
        try jw.writer.writeAll(raw.text);
        jw.endWriteRaw();
    }

    pub fn jsonParse(
        allocator: Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !Raw {
        const value = try std.json.Value.jsonParse(allocator, source, options);
        const text = try std.json.Stringify.valueAlloc(allocator, value, .{});
        return .{ .text = text };
    }
};

pub const Limits = struct {
    cpu_millis: ?u32 = null,
    memory_bytes: ?u64 = null,
};

pub const Requests = struct {
    cpu_millis: u32,
    memory_bytes: u64,
};

pub const Pair = [2][]const u8;

pub const Service = struct {
    v: u32 = 1,
    name: []const u8,
    image: []const u8,
    replicas: u32,
    command: []const []const u8,
    env: []const Pair = &.{},
    limits: Limits = .{},
    generation: u64,
    next_replica: u64,
    applied_by: []const u8 = "",
    request_id: []const u8 = "",
};

pub const Replica = struct {
    v: u32 = 1,
    id: []const u8,
    service: []const u8,
    generation: u64,
    node: []const u8,
    image: []const u8,
    command: []const []const u8,
    env: []const Pair = &.{},
    limits: Limits = .{},
    requests: ?Requests = null,
};

pub const Node = struct {
    v: u32 = 1,
    name: []const u8,
    agent_version: []const u8 = "",
    address: []const u8 = "",
    capacity: Requests,
    labels: []const []const u8 = &.{},
};

pub const ObservedStatus = enum { starting, running, stopped };

pub const ExitKind = enum { exited, signaled, oom, pid_limit, start_failed, lost };

pub const Exit = struct {
    kind: ExitKind,
    code: ?u8 = null,
    signal: ?u8 = null,

    pub fn equal(first: Exit, second: Exit) bool {
        if (first.kind != second.kind) return false;
        if (first.code != second.code) return false;
        return first.signal == second.signal;
    }
};

pub const Observed = struct {
    v: u32 = 1,
    replica: []const u8,
    node: []const u8,
    generation: u64,
    status: ObservedStatus,
    exit: ?Exit = null,
    diagnostic: ?Raw = null,
    started_at_ms: ?u64 = null,
    reported_at_ms: u64,
};

pub const SubjectKind = enum { service, replica, node };

pub const Subject = struct {
    kind: SubjectKind,
    name: []const u8,
};

pub const CauseKind = enum { decision, observed, desired, lease_expired, resync };

/// One struct for every kind, with the members that kind uses (docs/keys.md); the rest are absent.
pub const Cause = struct {
    kind: CauseKind,
    id: ?[]const u8 = null,
    key: ?[]const u8 = null,
    revision: ?u64 = null,
    lease: ?u64 = null,
    ttl_ms: ?u64 = null,
};

pub const Decision = struct {
    v: u32 = 1,
    id: []const u8,
    at_ms: u64,
    actor: []const u8,
    action: []const u8,
    subject: Subject,
    reason: []const u8,
    change: ?[]const u8 = null,
    cause: Cause,
    cause_diagnostic: ?Raw = null,
};

pub const IndexEntry = struct {
    v: u32 = 1,
    id: []const u8,
    at_ms: u64,
    action: []const u8,
    summary: []const u8,
};

/// `<at_ms, 13 digits>-<controller instance, 4 hex>-<counter, 4 digits>`.
pub const decision_id_bytes: u32 = 13 + 1 + 4 + 1 + 4;

pub const DecisionId = struct {
    bytes: [decision_id_bytes]u8 = undefined,

    pub fn slice(id: *const DecisionId) []const u8 {
        return id.bytes[0..decision_id_bytes];
    }
};

pub fn decision_id(at_ms: u64, instance: u16, counter: u32) DecisionId {
    assert(at_ms <= constants.decision_time_ms_max);
    assert(counter < constants.decision_counter_modulus);
    var id: DecisionId = .{};
    const format = "{d:0>13}-{x:0>4}-{d:0>4}";
    const written = std.fmt.bufPrint(&id.bytes, format, .{ at_ms, instance, counter });
    // Cannot fail: the three fields are bounded by the asserts above, and the buffer is their sum.
    assert((written catch unreachable).len == decision_id_bytes);
    return id;
}

/// The `at_ms` an id carries, or null if `id` is not of the form `decision_id` writes.
pub fn decision_id_time(id: []const u8) ?u64 {
    if (id.len != decision_id_bytes) return null;
    if (id[13] != '-') return null;
    if (id[18] != '-') return null;
    return std.fmt.parseInt(u64, id[0..13], 10) catch null;
}

// ---- JSON ----------------------------------------------------------------------------------

/// Encodes a record as compact JSON in `arena`.
pub fn encode(arena: Allocator, value: anytype, diag: *Diag) Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const options: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };
    std.json.Stringify.value(value, options, &out.writer) catch
        return failures.no_memory(diag);
    const bytes = out.toOwnedSlice() catch return failures.no_memory(diag);
    assert(bytes.len > 0);
    if (bytes.len > constants.store_value_bytes_max) return failures.no_memory(diag);
    return bytes;
}

/// Parses the value of `kv` as a `T`. A value that is not one is ZC-E0301 naming the key.
pub fn read(comptime T: type, arena: Allocator, kv: store.KeyValue, diag: *Diag) Error!T {
    assert(kv.key.len > 0);
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    const parsed = std.json.parseFromSliceLeaky(T, arena, kv.value, options) catch |err| {
        if (err == error.OutOfMemory) return failures.no_memory(diag);
        return malformed(diag, kv.key, @typeName(T));
    };
    return parsed;
}

/// Raises ZC-E0301 for the key and returns the error.
pub fn malformed(diag: *Diag, key: []const u8, comptime type_name: []const u8) error{Malformed} {
    assert(diag.code == null);
    diag.raise(.E0301);
    const kind = comptime kind_name(type_name);
    diag.cause("the value at {s} is not a valid {s} record", .{ key, kind });
    diag.fix(.{ .sentence = "fix or delete that key; the next pass tries again" });
    return error.Malformed;
}

fn kind_name(comptime type_name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, type_name, '.');
    const start = if (dot) |index| index + 1 else 0;
    return type_name[start..];
}

/// A diagnostic as the compact JSON text a record embeds.
pub fn diagnostic_raw(arena: Allocator, diagnostic: *const Diagnostic, diag: *Diag) Error!Raw {
    var out: std.Io.Writer.Allocating = .init(arena);
    zigbox.diagnostic.write_json(&out.writer, diagnostic) catch return failures.no_memory(diag);
    const bytes = out.toOwnedSlice() catch return failures.no_memory(diag);
    assert(bytes.len > 1);
    assert(bytes[bytes.len - 1] == '\n');
    return .{ .text = bytes[0 .. bytes.len - 1] };
}

/// Parses an embedded diagnostic into `out` (initialised in place). False if it is not one.
pub fn diagnostic_parse(out: *Diagnostic, raw: Raw) bool {
    assert(raw.text.len > 0);
    zigbox.diagnostic.parse_json(out, raw.text) catch return false;
    if (std.mem.startsWith(u8, out.code.slice(), "ZBX-")) out.set_docs(&zigbox.product.Product.zbx);
    if (std.mem.startsWith(u8, out.code.slice(), "ZC-")) out.set_docs(&diag_mod.product);
    return true;
}

/// A short rendering of an exit for sentences: "was killed by signal 9 (SIGKILL)".
pub fn exit_text(exit: Exit, buffer: []u8) []const u8 {
    assert(buffer.len >= 64);
    const text = switch (exit.kind) {
        .exited => std.fmt.bufPrint(buffer, "exited with code {d}", .{exit.code orelse 0}),
        .signaled => signaled_text(buffer, exit.signal orelse 0),
        .oom => std.fmt.bufPrint(buffer, "ran out of memory", .{}),
        .pid_limit => std.fmt.bufPrint(buffer, "hit its process limit", .{}),
        .start_failed => std.fmt.bufPrint(buffer, "failed to start", .{}),
        .lost => std.fmt.bufPrint(buffer, "was lost", .{}),
    };
    // Cannot fail: every text above is under 64 bytes, and the buffer has at least that.
    return text catch unreachable;
}

fn signaled_text(buffer: []u8, signal: u8) std.fmt.BufPrintError![]u8 {
    if (signal == 9) return std.fmt.bufPrint(buffer, "was killed by signal 9 (SIGKILL)", .{});
    if (signal == 15) return std.fmt.bufPrint(buffer, "was stopped by signal 15 (SIGTERM)", .{});
    return std.fmt.bufPrint(buffer, "was killed by signal {d}", .{signal});
}

// ---- Tests ---------------------------------------------------------------------------------

const testing = std.testing;

test "keys follow docs/keys.md" {
    // Goal: the layout of keys.md has one implementation. Method: build each kind and compare.
    try testing.expectEqualStrings("/services/hello", service_key("hello").slice());
    try testing.expectEqualStrings("/replicas/hello/", replicas_prefix("hello").slice());
    const replica = replica_key("hello", "hello-9");
    try testing.expectEqualStrings("/replicas/hello/hello-9", replica.slice());
    const observed = observed_key("node1", "hello-9");
    try testing.expectEqualStrings("/observed/node1/hello-9", observed.slice());
    try testing.expectEqualStrings("/nodes/node1", node_key("node1").slice());
    const id = decision_id(1761350000123, 1, 7);
    try testing.expectEqualStrings("1761350000123-0001-0007", id.slice());
    const index = index_key(.service, "hello", id.slice());
    const expected = "/decisions-by-subject/service/hello/1761350000123-0001-0007";
    try testing.expectEqualStrings(expected, index.slice());
    try testing.expectEqual(@as(?u64, 1761350000123), decision_id_time(id.slice()));
    try testing.expectEqual(@as(?u64, null), decision_id_time("x"));
}

test "names are hostname labels and replica ids carry their number" {
    // Goal: the boundary where a name becomes invalid, and the number of a replica id.
    try testing.expect(name_problem("hello-1", 48) == null);
    try testing.expectEqual(NameProblem.empty, name_problem("", 48).?);
    try testing.expectEqual(NameProblem.bad_character, name_problem("Hello", 48).?);
    try testing.expectEqual(NameProblem.hyphen_at_edge, name_problem("a-", 48).?);
    try testing.expectEqual(NameProblem.too_long, name_problem("aaaa", 3).?);
    try testing.expectEqual(@as(?u32, 9), replica_number("hello", "hello-9"));
    try testing.expectEqual(@as(?u32, null), replica_number("hello", "hello-x"));
    try testing.expectEqual(@as(?u32, null), replica_number("hello", "hellofoo-1"));
    try testing.expectEqual(@as(?u32, null), replica_number("hello", "hello-"));
}

test "a service round-trips through JSON and ignores members it does not know" {
    // Goal: the shape of keys.md survives encode and read, a newer writer's extra member is
    // ignored, and a value that is not a service is ZC-E0301 naming the key.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    const service: Service = .{
        .name = "hello",
        .image = "b3:51aa9c03",
        .replicas = 3,
        .command = &.{ "sh", "-c", "sleep 1" },
        .env = &.{.{ "KEY", "value" }},
        .limits = .{ .cpu_millis = 500 },
        .generation = 4,
        .next_replica = 17,
    };
    const bytes = try encode(arena, service, &diag);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"env\":[[\"KEY\",\"value\"]]") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "memory_bytes") == null);
    const kv: store.KeyValue = .{
        .key = "/services/hello",
        .value = bytes,
        .create_revision = 1,
        .mod_revision = 1,
    };
    const back = try read(Service, arena, kv, &diag);
    try testing.expectEqual(@as(u32, 3), back.replicas);
    try testing.expectEqualStrings("value", back.env[0][1]);

    var extra: store.KeyValue = kv;
    extra.value = "{\"v\":1,\"name\":\"a\",\"image\":\"i\",\"replicas\":1,\"command\":[\"x\"]," ++
        "\"generation\":1,\"next_replica\":1,\"added_later\":{\"x\":[1]}}";
    try testing.expectEqualStrings("a", (try read(Service, arena, extra, &diag)).name);

    extra.value = "{\"v\":1,\"name\":5}";
    try testing.expectError(error.Malformed, read(Service, arena, extra, &diag));
    try testing.expectEqual(codes.Code.E0301, diag.code.?);
    try testing.expectEqualStrings(
        "the value at /services/hello is not a valid Service record",
        diag.last_cause().?,
    );
}

test "an embedded diagnostic is kept as text and parses back" {
    // Goal: observed state carries a diagnostic through the store unchanged. Method: build one,
    // embed it in an observed record, round-trip the record, parse the diagnostic out.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    diag.raise(.E0205);
    diag.cause("lease 7 is gone", .{});
    diag.fix(.{ .sentence = "register again" });
    var finished: Diagnostic = undefined;
    diag_mod.to_diagnostic(&finished, &diag);
    diag.reset();

    const raw = try diagnostic_raw(arena, &finished, &diag);
    const observed: Observed = .{
        .replica = "hello-1",
        .node = "node1",
        .generation = 1,
        .status = .stopped,
        .exit = .{ .kind = .start_failed },
        .diagnostic = raw,
        .reported_at_ms = 5,
    };
    const bytes = try encode(arena, observed, &diag);
    const kv: store.KeyValue = .{
        .key = "/observed/node1/hello-1",
        .value = bytes,
        .create_revision = 1,
        .mod_revision = 1,
    };
    const back = try read(Observed, arena, kv, &diag);
    var parsed: Diagnostic = undefined;
    try testing.expect(diagnostic_parse(&parsed, back.diagnostic.?));
    try testing.expectEqualStrings("ZC-E0205", parsed.code.slice());
    try testing.expectEqualStrings("lease 7 is gone", parsed.last_cause().?);
}

test "a cause carries only the members of its kind" {
    // Goal: the wire form of keys.md's cause table: absent members are not written.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag: Diag = undefined;
    diag.reset();
    const cause: Cause = .{ .kind = .observed, .key = "/observed/n/r", .revision = 4 };
    const bytes = try encode(arena_state.allocator(), cause, &diag);
    const expected = "{\"kind\":\"observed\",\"key\":\"/observed/n/r\",\"revision\":4}";
    try testing.expectEqualStrings(expected, bytes);
}
