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
pub const prefix_assigned = "/assigned/";
pub const prefix_allocations = "/allocations/";
pub const prefix_audit_allocations = "/audit/allocations/";
pub const prefix_node_status = "/node-status/";
pub const prefix_summaries = "/decision-summaries/";

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

pub fn assigned_prefix(node: []const u8) Key {
    assert(name_problem(node, constants.node_name_bytes_max) == null);
    return Key.build(&.{ prefix_assigned, node, "/" });
}

pub fn assigned_key(node: []const u8, replica: []const u8) Key {
    assert(name_problem(replica, constants.node_name_bytes_max) == null);
    return Key.build(&.{ prefix_assigned, node, "/", replica });
}

pub fn allocation_key(node: []const u8) Key {
    assert(name_problem(node, constants.node_name_bytes_max) == null);
    return Key.build(&.{ prefix_allocations, node });
}

pub fn audit_key(node: []const u8) Key {
    assert(name_problem(node, constants.node_name_bytes_max) == null);
    return Key.build(&.{ prefix_audit_allocations, node });
}

pub fn node_status_key(node: []const u8) Key {
    assert(name_problem(node, constants.node_name_bytes_max) == null);
    return Key.build(&.{ prefix_node_status, node });
}

pub fn summary_key(kind: SubjectKind, name: []const u8, action: []const u8, cause: CauseKind) Key {
    assert(name_problem(name, constants.node_name_bytes_max) == null);
    assert(action.len > 0);
    assert(action.len <= action_bytes_max);
    const parts = [_][]const u8{ prefix_summaries, @tagName(kind), "/", name, "/", action, "/" };
    return Key.build(&(parts ++ .{@tagName(cause)}));
}

/// The longest action name of a decision; it is part of a summary key.
pub const action_bytes_max: u32 = 48;

comptime {
    // The longest summary key.
    const summary = prefix_summaries.len + "service".len + 1 + constants.node_name_bytes_max + 1 +
        action_bytes_max + 1 + "lease_expired".len;
    assert(summary <= constants.store_key_bytes_max);
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
    v: u32 = 2,
    replica: []const u8,
    node: []const u8,
    generation: u64,
    status: ObservedStatus,
    exit: ?Exit = null,
    diagnostic: ?Raw = null,
    started_at_ms: ?u64 = null,
    reported_at_ms: u64,
    /// The `/nodes/<node>` revision of the agent's tenure when it reported. Absent in C0 records.
    tenure: ?u64 = null,
    /// The `/assigned/<node>/<replica>` revision it ran under (the placement epoch). Absent in C0
    /// records.
    assignment: ?u64 = null,
};

/// The placement: the scheduler's decision to run a replica on a node.
pub const Assigned = struct {
    v: u32 = 1,
    replica: []const u8,
    service: []const u8,
    requests: Requests,
    reason: []const u8,
};

/// The authoritative accounting of a node: the sum of the `requests` of its assignments.
pub const Allocation = struct {
    v: u32 = 1,
    allocated: Requests,
    count: u32,
    /// The `/nodes/<node>` revision whose capacity this record was checked against.
    node_revision: u64,
};

pub const Tally = struct {
    allocated: Requests,
    count: u32,
};

/// An open finding of the allocation auditor.
pub const Audit = struct {
    v: u32 = 1,
    recorded: Tally,
    reconstructed: Tally,
    revision: u64,
    decision: []const u8,
};

pub const NodeState = enum { ready, lost, fenced };

pub const NodeStatus = struct {
    v: u32 = 1,
    state: NodeState,
    /// The `/nodes/<node>` revision the state judged.
    tenure: u64,
    at_ms: u64,
    decision: []const u8,
};

/// A count over immutable decisions; never a cause.
pub const Summary = struct {
    v: u32 = 1,
    count: u64,
    first_at_ms: u64,
    last_at_ms: u64,
    newest: []const u8,
};

/// The format version each record kind is written in. A reader accepts every version up to it.
pub fn version_current(comptime T: type) u32 {
    return switch (T) {
        Observed, Decision => 2,
        else => 1,
    };
}

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
    v: u32 = 2,
    id: []const u8,
    at_ms: u64,
    actor: []const u8,
    action: []const u8,
    subject: Subject,
    reason: []const u8,
    change: ?[]const u8 = null,
    cause: Cause,
    cause_diagnostic: ?Raw = null,
    /// The fields of the cause's key that the decision used, as a JSON object of at most
    /// `decision_evidence_bytes_max` bytes. Absent in C0 records.
    cause_evidence: ?Raw = null,
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
    if (@hasField(T, "v")) {
        const known = version_current(T);
        if (parsed.v > known) return too_new(diag, kv.key, parsed.v, known);
    }
    return parsed;
}

/// Raises ZC-E0303: the value at `key` was written in a newer format than this release reads.
fn too_new(diag: *Diag, key: []const u8, found: u32, known: u32) error{Malformed} {
    assert(found > known);
    assert(diag.code == null);
    diag.raise(.E0303);
    diag.cause("the value at {s} is version {d}; this release reads up to version {d}", .{
        key, found, known,
    });
    diag.fix(.{ .sentence = "run the zcube release that wrote it, or upgrade this one" });
    return error.Malformed;
}

/// Raises ZC-E0301 for the key and returns the error.
pub fn malformed(diag: *Diag, key: []const u8, comptime type_name: []const u8) error{Malformed} {
    raise_malformed(diag, key, type_name);
    return error.Malformed;
}

/// Fills `diag` as `malformed` does, for a caller that reports the diagnostic and does not fail.
pub fn raise_malformed(diag: *Diag, key: []const u8, comptime type_name: []const u8) void {
    assert(diag.code == null);
    diag.raise(.E0301);
    const kind = comptime kind_name(type_name);
    diag.cause("the value at {s} is not a valid {s} record", .{ key, kind });
    diag.fix(.{ .sentence = "fix or delete that key; the next pass tries again" });
}

fn kind_name(comptime type_name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, type_name, '.');
    const start = if (dot) |index| index + 1 else 0;
    return type_name[start..];
}

/// A diagnostic as the compact JSON text a record embeds.
pub fn diagnostic_raw(arena: Allocator, diagnostic: *const Diagnostic, diag: *Diag) Error!Raw {
    var out: std.Io.Writer.Allocating = .init(arena);
    // The docs link is derived from the code by whoever renders it (docs/api.md), so it is not
    // stored.
    var bare = diagnostic.*;
    bare.docs = .{};
    zigbox.diagnostic.write_json(&out.writer, &bare) catch return failures.no_memory(diag);
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

test "the keys of C1 follow authority.md" {
    // Goal: one implementation of the new layout. Method: build each and compare.
    try testing.expectEqualStrings("/assigned/node1/", assigned_prefix("node1").slice());
    const placed = assigned_key("node1", "hello-9");
    try testing.expectEqualStrings("/assigned/node1/hello-9", placed.slice());
    try testing.expectEqualStrings("/allocations/node1", allocation_key("node1").slice());
    try testing.expectEqualStrings("/audit/allocations/node1", audit_key("node1").slice());
    try testing.expectEqualStrings("/node-status/node1", node_status_key("node1").slice());
    const summary = summary_key(.service, "hello", "replace_replica", .observed);
    const expected = "/decision-summaries/service/hello/replace_replica/observed";
    try testing.expectEqualStrings(expected, summary.slice());
}

test "the longest of the new keys fit the key limit" {
    // Goal: every key stays within 512 bytes by construction. Method: build each at its bounds.
    const node: [constants.node_name_bytes_max]u8 = @splat('n');
    const action: [action_bytes_max]u8 = @splat('a');
    const summary = summary_key(.service, &node, &action, .lease_expired);
    try testing.expect(summary.len <= constants.store_key_bytes_max);
    try testing.expect(assigned_key(&node, &node).len <= constants.store_key_bytes_max);
    try testing.expect(audit_key(&node).len <= constants.store_key_bytes_max);
}

fn kv_of(key: []const u8, value: []const u8) store.KeyValue {
    return .{ .key = key, .value = value, .create_revision = 1, .mod_revision = 1 };
}

test "each record of C1 encodes and reads back" {
    // Goal: the shapes of keys.md survive encode and read, and the size of an assignment is
    // known. Method: round-trip one of each.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();

    const requests: Requests = .{ .cpu_millis = 250, .memory_bytes = 134217728 };
    const assigned: Assigned = .{
        .replica = "hello-1",
        .service = "hello",
        .requests = requests,
        .reason = "node1 is the only node, and it fits 250m CPU and 128 MiB",
    };
    const assigned_bytes = try encode(arena, assigned, &diag);
    try testing.expectEqualStrings(
        "{\"v\":1,\"replica\":\"hello-1\",\"service\":\"hello\"," ++
            "\"requests\":{\"cpu_millis\":250,\"memory_bytes\":134217728}," ++
            "\"reason\":\"node1 is the only node, and it fits 250m CPU and 128 MiB\"}",
        assigned_bytes,
    );
    // A node holds at most agent_node_replicas_max of these in one list page; the value is far
    // below the store's bound even with the longest names and a reason of the longest sort.
    try testing.expect(assigned_bytes.len < 256);
    const back = try read(Assigned, arena, kv_of("/assigned/node1/hello-1", assigned_bytes), &diag);
    try testing.expectEqual(@as(u64, 134217728), back.requests.memory_bytes);

    const allocation: Allocation = .{ .allocated = requests, .count = 1, .node_revision = 3 };
    const allocation_bytes = try encode(arena, allocation, &diag);
    try testing.expectEqualStrings(
        "{\"v\":1,\"allocated\":{\"cpu_millis\":250,\"memory_bytes\":134217728}," ++
            "\"count\":1,\"node_revision\":3}",
        allocation_bytes,
    );
    const alloc_kv = kv_of("/allocations/node1", allocation_bytes);
    try testing.expectEqual(@as(u32, 1), (try read(Allocation, arena, alloc_kv, &diag)).count);
}

test "an audit finding, a node status and a summary encode and read back" {
    // Goal: the rest of the shapes of keys.md; their JSON here is the JSON documented there.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    const requests: Requests = .{ .cpu_millis = 250, .memory_bytes = 134217728 };
    const tally: Tally = .{ .allocated = requests, .count = 1 };
    const empty: Tally = .{ .allocated = .{ .cpu_millis = 0, .memory_bytes = 0 }, .count = 0 };
    const audit: Audit = .{
        .recorded = tally,
        .reconstructed = empty,
        .revision = 9,
        .decision = "1761350000123-0001-0007",
    };
    const audit_bytes = try encode(arena, audit, &diag);
    try testing.expectEqualStrings(
        "{\"v\":1,\"recorded\":{\"allocated\":{\"cpu_millis\":250," ++
            "\"memory_bytes\":134217728},\"count\":1}," ++
            "\"reconstructed\":{\"allocated\":{\"cpu_millis\":0," ++
            "\"memory_bytes\":0},\"count\":0}," ++
            "\"revision\":9,\"decision\":\"1761350000123-0001-0007\"}",
        audit_bytes,
    );
    const audit_kv = kv_of("/audit/allocations/node1", audit_bytes);
    try testing.expectEqual(@as(u64, 9), (try read(Audit, arena, audit_kv, &diag)).revision);

    const status: NodeStatus = .{
        .state = .fenced,
        .tenure = 3,
        .at_ms = 10,
        .decision = "1761350000123-0001-0008",
    };
    const status_bytes = try encode(arena, status, &diag);
    try testing.expectEqualStrings(
        "{\"v\":1,\"state\":\"fenced\",\"tenure\":3,\"at_ms\":10," ++
            "\"decision\":\"1761350000123-0001-0008\"}",
        status_bytes,
    );
    try testing.expect(std.mem.indexOf(u8, status_bytes, "\"state\":\"fenced\"") != null);
    const status_kv = kv_of("/node-status/node1", status_bytes);
    const status_back = try read(NodeStatus, arena, status_kv, &diag);
    try testing.expectEqual(NodeState.fenced, status_back.state);

    const summary: Summary = .{
        .count = 142,
        .first_at_ms = 1,
        .last_at_ms = 2,
        .newest = "1761350000123-0001-0009",
    };
    const summary_bytes = try encode(arena, summary, &diag);
    try testing.expectEqualStrings(
        "{\"v\":1,\"count\":142,\"first_at_ms\":1,\"last_at_ms\":2," ++
            "\"newest\":\"1761350000123-0001-0009\"}",
        summary_bytes,
    );
    const summary_name = "/decision-summaries/service/hello/replace_replica/observed";
    const summary_kv = kv_of(summary_name, summary_bytes);
    try testing.expectEqual(@as(u64, 142), (try read(Summary, arena, summary_kv, &diag)).count);
}

test "observed and decision write version 2 with their new members, and read them back" {
    // Goal: the members C1 adds are optional, and the version moves with the shape.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    const observed: Observed = .{
        .replica = "hello-1",
        .node = "node1",
        .generation = 1,
        .status = .running,
        .reported_at_ms = 5,
        .tenure = 3,
        .assignment = 4,
    };
    const bytes = try encode(arena, observed, &diag);
    try testing.expect(std.mem.startsWith(u8, bytes, "{\"v\":2,"));
    const kv = kv_of("/observed/node1/hello-1", bytes);
    const back = try read(Observed, arena, kv, &diag);
    try testing.expectEqual(@as(?u64, 4), back.assignment);

    const decision: Decision = .{
        .id = "1761350000123-0001-0007",
        .at_ms = 1,
        .actor = "scheduler",
        .action = "place_replica",
        .subject = .{ .kind = .replica, .name = "hello-1" },
        .reason = "r",
        .cause = .{ .kind = .desired, .key = "/services/hello", .revision = 2 },
        .cause_evidence = .{ .text = "{\"replicas\":3,\"generation\":1}" },
    };
    const decision_bytes = try encode(arena, decision, &diag);
    try testing.expect(std.mem.startsWith(u8, decision_bytes, "{\"v\":2,"));
    const decision_kv = kv_of("/decisions/1761350000123-0001-0007", decision_bytes);
    const decoded = try read(Decision, arena, decision_kv, &diag);
    const evidence = decoded.cause_evidence.?.text;
    try testing.expectEqualStrings("{\"replicas\":3,\"generation\":1}", evidence);
}

/// Records captured from a real C0 server and agent (src/testdata/README.md), one `key<TAB>value`
/// per line, values exactly as the store held them.
const c0_store = @embedFile("testdata/c0_store.txt");

test "records a C0 build wrote still read" {
    // Goal: a stored value is read by the next release. Method: read every record of a store a C0
    // build produced, as the type its key says, and check what C1 adds is absent.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    var seen: [5]u32 = @splat(0);
    var lines = std.mem.splitScalar(u8, c0_store, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t').?;
        const kv = kv_of(line[0..tab], line[tab + 1 ..]);
        if (std.mem.startsWith(u8, kv.key, prefix_services)) {
            const record = try read(Service, arena, kv, &diag);
            try testing.expectEqual(@as(u32, 1), record.v);
            seen[0] += 1;
        } else if (std.mem.startsWith(u8, kv.key, prefix_replicas)) {
            const record = try read(Replica, arena, kv, &diag);
            try testing.expect(record.node.len > 0 or record.requests == null);
            seen[1] += 1;
        } else if (std.mem.startsWith(u8, kv.key, prefix_observed)) {
            const record = try read(Observed, arena, kv, &diag);
            try testing.expectEqual(@as(u32, 1), record.v);
            try testing.expectEqual(@as(?u64, null), record.tenure);
            try testing.expectEqual(@as(?u64, null), record.assignment);
            seen[2] += 1;
        } else if (std.mem.startsWith(u8, kv.key, prefix_decisions)) {
            const record = try read(Decision, arena, kv, &diag);
            try testing.expectEqual(@as(u32, 1), record.v);
            try testing.expect(record.cause_evidence == null);
            seen[3] += 1;
        } else if (std.mem.startsWith(u8, kv.key, prefix_nodes)) {
            _ = try read(Node, arena, kv, &diag);
            seen[4] += 1;
        }
    }
    for (seen) |count| try testing.expect(count > 0);
}

test "a newer version is refused with ZC-E0303, not as malformed" {
    // Goal: a value from a newer release is named and left alone. Method: bump the version of a
    // real record, and of a kind that is still at 1.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    const observed = "{\"v\":3,\"replica\":\"hello-1\",\"node\":\"node1\",\"generation\":1," ++
        "\"status\":\"running\",\"reported_at_ms\":5}";
    const kv = kv_of("/observed/node1/hello-1", observed);
    try testing.expectError(error.Malformed, read(Observed, arena, kv, &diag));
    try testing.expectEqual(codes.Code.E0303, diag.code.?);
    try testing.expectEqualStrings(
        "the value at /observed/node1/hello-1 is version 3; this release reads up to version 2",
        diag.last_cause().?,
    );
    // Version 1 of a record that C1 has not changed is the newest there is.
    diag.reset();
    const node_kv = kv_of("/nodes/n", "{\"v\":2,\"name\":\"n\",\"capacity\":{\"cpu_millis\":1," ++
        "\"memory_bytes\":1}}");
    try testing.expectError(error.Malformed, read(Node, arena, node_kv, &diag));
    try testing.expectEqual(codes.Code.E0303, diag.code.?);
}
