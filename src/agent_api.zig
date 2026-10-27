//! The agent's endpoints of docs/api.md ("Agent endpoints (slice 6a)") as functions from bytes to
//! bytes, like the rest of the API: a request in, a JSON body out, no socket and no wait.
//! `Api.route` hands every path under `/v1/agent/` to `route` here, so request ids, the error body
//! and the status that a diagnostic's blame decides are the API's, unchanged.
//!
//! Everything is scoped to one node, named in the path. The agent core (`agent.zig`) is written
//! against `Store`; the shell's `RemoteStore` (`agent_remote.zig`) turns the four store calls the
//! core makes into these endpoints, so the core runs unchanged on the other side of HTTP:
//!
//!   POST /v1/agent/nodes/{node}/lease                  lease_grant
//!   POST /v1/agent/nodes/{node}/lease/{id}/keepalive   lease_keepalive
//!   PUT  /v1/agent/nodes/{node}                        the put of /nodes/<node> on a lease
//!   GET  /v1/agent/nodes/{node}/replicas               the node's desired replicas, with env
//!   GET  /v1/agent/nodes/{node}/observed               what the node has reported
//!   POST /v1/agent/nodes/{node}/observed               one transaction of puts and deletes
//!   GET  /v1/agent/nodes/{node}/watch?from=&timeout=   "something changed", a long poll
//!
//! **The watch carries no events.** It answers whether a key under the watched prefix changed
//! since revision `from`, with a bookmark. The agent reconciles by level, so it lists again and
//! lets the core decide; there is no gap to close and no event to lose. The wait is the shell's
//! (`Reply.hold_ms`), as for `GET /v1/watch`.
//!
//! **These endpoints return `env` values** (the agent must start the container with them) and
//! write the store, and they are unauthenticated until the API has auth. They are for a private
//! address, like the write endpoints.
//!
//! **Validation.** A body comes from the network and is never trusted to satisfy an assertion of
//! `Store`: keys are built here from validated names, the observed records must name the node and
//! replica of their key, a transaction is at most `agent_report_ops_max` operations with no key
//! twice, and unknown fields are refused (ZC-E0104).

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const records = @import("records.zig");
const store = @import("store.zig");
const text_util = @import("text.zig");

const Context = controller.Context;

/// The route failed and `ctx.diag` says why. Same set as `api.zig`'s, so `try` passes it up.
pub const Failure = error{Failed};

/// A reply that is not yet a `Response`: the same fields as `api.zig`'s.
pub const Reply = struct {
    body: []const u8,
    hold_ms: u32 = 0,
    hold_prefixes: []const []const u8 = &.{},
};

/// The keys whose change ends a held watch. C0 has one node and the scheduler writes no index, so
/// it is every replica; C1 narrows it to `/assigned/<node>/` (docs/keys.md) without changing
/// the endpoint's shape.
pub const watch_prefixes = [_][]const u8{records.prefix_replicas};

const Parts = std.mem.SplitIterator(u8, .scalar);

/// Routes one request under `/v1/agent/`. `parts` is positioned after "agent".
pub fn route(
    ctx: *const Context,
    method: []const u8,
    parts: *Parts,
    query: []const u8,
    body: []const u8,
    hold: bool,
) Failure!Reply {
    assert(ctx.diag.code == null);
    const nodes = parts.next() orelse return no_such(ctx, "/v1/agent");
    if (!std.mem.eql(u8, nodes, "nodes")) return no_such(ctx, "/v1/agent/");
    const node = parts.next() orelse return no_such(ctx, "/v1/agent/nodes");
    if (records.name_problem(node, constants.node_name_bytes_max) != null) {
        return bad_request(ctx, "node", "is not a valid node name");
    }
    const call: Call = .{
        .ctx = ctx,
        .node = node,
        .method = method,
        .query = query,
        .body = body,
        .hold = hold,
        .parts = parts,
    };
    const what = parts.next() orelse return call.register();
    if (std.mem.eql(u8, what, "lease")) return call.lease();
    if (std.mem.eql(u8, what, "replicas")) return call.replicas();
    if (std.mem.eql(u8, what, "observed")) return call.observed();
    if (std.mem.eql(u8, what, "watch")) return call.watch();
    return no_such(ctx, "/v1/agent/nodes/<node>/<that>");
}

const Call = struct {
    ctx: *const Context,
    node: []const u8,
    method: []const u8,
    query: []const u8,
    body: []const u8,
    hold: bool,
    parts: *Parts,

    fn require_method(call: Call, wanted: []const u8) Failure!void {
        if (std.mem.eql(u8, call.method, wanted)) return;
        const problem = "this endpoint answers a different method: see docs/api.md";
        return bad_request(call.ctx, "method", problem);
    }

    fn no_more(call: Call) Failure!void {
        if (call.parts.next() != null) return no_such(call.ctx, "that path");
    }

    // ---- PUT /v1/agent/nodes/{node} ----

    fn register(call: Call) Failure!Reply {
        const ctx = call.ctx;
        try call.require_method("PUT");
        try no_query(ctx, call.query);
        const input = try parse_body(RegisterBody, ctx, call.body);
        if (input.lease == store.lease_none) return bad_request(ctx, "lease", "must not be 0");
        const capacity = input.capacity;
        if (capacity.cpu_millis == 0) return bad_request(ctx, "capacity", "needs cpu_millis");
        if (capacity.memory_bytes == 0) return bad_request(ctx, "capacity", "needs memory_bytes");
        try check_text(ctx, "agent_version", input.agent_version, node_text_bytes_max);
        try check_text(ctx, "address", input.address, node_text_bytes_max);
        if (input.labels.len > node_labels_max) return bad_request(ctx, "labels", "has too many");
        for (input.labels) |label| try check_text(ctx, "labels", label, node_text_bytes_max);
        const node: records.Node = .{
            .name = call.node,
            .agent_version = input.agent_version,
            .address = input.address,
            .capacity = capacity,
            .labels = input.labels,
        };
        const key = records.node_key(call.node);
        const value = records.encode(ctx.arena, node, ctx.diag) catch return propagate(ctx);
        const put: store.Put = .{ .key = key.slice(), .value = value, .lease = input.lease };
        const op: store.Op = .{ .put = put };
        const result = ctx.store.txn(.{ .on_success = &.{op} }, ctx.diag) catch
            return propagate(ctx);
        return reply(ctx, .{ .revision = result.revision });
    }

    // ---- POST /v1/agent/nodes/{node}/lease[/{id}/keepalive] ----

    fn lease(call: Call) Failure!Reply {
        const ctx = call.ctx;
        try call.require_method("POST");
        try no_query(ctx, call.query);
        const id_text = call.parts.next() orelse return call.lease_grant();
        const keepalive = call.parts.next() orelse return no_such(ctx, "that path");
        if (!std.mem.eql(u8, keepalive, "keepalive")) return no_such(ctx, "that path");
        try call.no_more();
        const id = std.fmt.parseInt(u64, id_text, 10) catch
            return bad_request(ctx, "lease", "is not a number");
        if (id == store.lease_none) return bad_request(ctx, "lease", "must not be 0");
        const granted = ctx.store.lease_keepalive(id, ctx.diag) catch return propagate(ctx);
        return reply(ctx, .{ .lease = .{ .id = granted.id, .ttl_ms = granted.ttl_ms } });
    }

    fn lease_grant(call: Call) Failure!Reply {
        const ctx = call.ctx;
        const input = try parse_body(LeaseBody, ctx, call.body);
        const granted = ctx.store.lease_grant(input.ttl_ms, ctx.diag) catch return propagate(ctx);
        return reply(ctx, .{ .lease = .{ .id = granted.id, .ttl_ms = granted.ttl_ms } });
    }

    // ---- GET /v1/agent/nodes/{node}/replicas ----

    fn replicas(call: Call) Failure!Reply {
        const ctx = call.ctx;
        try call.require_method("GET");
        try no_query(ctx, call.query);
        try call.no_more();
        const all = controller.list_all(
            records.Replica,
            ctx,
            records.prefix_replicas,
            null,
            constants.replicas_max,
        ) catch return propagate(ctx);
        var mine: std.ArrayList(Item(records.Replica)) = .empty;
        for (all.items) |entry| {
            if (!std.mem.eql(u8, entry.rec.node, call.node)) continue;
            if (mine.items.len == constants.agent_node_replicas_max) {
                return too_many(ctx, "replicas");
            }
            mine.append(ctx.arena, item_of(records.Replica, entry)) catch return no_memory(ctx);
        }
        return reply(ctx, .{ .revision = all.revision, .kvs = mine.items });
    }

    // ---- GET and POST /v1/agent/nodes/{node}/observed ----

    fn observed(call: Call) Failure!Reply {
        const ctx = call.ctx;
        try no_query(ctx, call.query);
        try call.no_more();
        if (std.mem.eql(u8, call.method, "POST")) return call.report();
        try call.require_method("GET");
        const prefix = records.observed_prefix(call.node);
        const all = controller.list_all(
            records.Observed,
            ctx,
            prefix.slice(),
            null,
            constants.replicas_max,
        ) catch return propagate(ctx);
        if (all.items.len > constants.agent_node_replicas_max) return too_many(ctx, "records");
        const items = ctx.arena.alloc(Item(records.Observed), all.items.len) catch
            return no_memory(ctx);
        for (all.items, items) |entry, *slot| slot.* = item_of(records.Observed, entry);
        return reply(ctx, .{ .revision = all.revision, .kvs = items });
    }

    /// One transaction: the observed records to write and the replica ids whose records go.
    fn report(call: Call) Failure!Reply {
        const ctx = call.ctx;
        const input = try parse_body(ObservedBody, ctx, call.body);
        const total = input.puts.len + input.deletes.len;
        if (total == 0) return bad_request(ctx, "body", "needs at least one put or delete");
        if (total > constants.agent_report_ops_max) {
            return bad_request(ctx, "body", "has more operations than one transaction holds");
        }
        var ops: [constants.agent_report_ops_max]store.Op = undefined;
        var count: u32 = 0;
        for (input.puts) |put| {
            try call.check_put(&put);
            const value = records.encode(ctx.arena, put.value, ctx.diag) catch
                return propagate(ctx);
            ops[count] = .{ .put = .{ .key = put.key, .value = value } };
            count += 1;
        }
        for (input.deletes) |key| {
            try call.check_key(key);
            ops[count] = .{ .delete = key };
            count += 1;
        }
        try no_duplicates(ctx, ops[0..count]);
        assert(count == total);
        const result = ctx.store.txn(.{ .on_success = ops[0..count] }, ctx.diag) catch
            return propagate(ctx);
        return reply(ctx, .{ .revision = result.revision });
    }

    /// The key is this node's observed key for the replica the record names, and the record says
    /// it is this node's: an agent can write its own node's reports and no other key.
    fn check_put(call: Call, put: *const ObservedPut) Failure!void {
        const ctx = call.ctx;
        const rec = &put.value;
        if (records.name_problem(rec.replica, constants.node_name_bytes_max) != null) {
            return bad_request(ctx, "puts", "a record names a replica that is not a valid name");
        }
        if (!std.mem.eql(u8, rec.node, call.node)) {
            return bad_request(ctx, "puts", "a record is for another node");
        }
        const wanted = records.observed_key(call.node, rec.replica);
        if (!std.mem.eql(u8, put.key, wanted.slice())) {
            return bad_request(ctx, "puts", "a key is not the observed key of its record");
        }
    }

    fn check_key(call: Call, key: []const u8) Failure!void {
        const ctx = call.ctx;
        const prefix = records.observed_prefix(call.node);
        if (!std.mem.startsWith(u8, key, prefix.slice())) {
            return bad_request(ctx, "deletes", "a key is not under this node's observed");
        }
        const rest = key[prefix.len..];
        if (records.name_problem(rest, constants.node_name_bytes_max) != null) {
            return bad_request(ctx, "deletes", "a key does not end in a replica id");
        }
    }

    // ---- GET /v1/agent/nodes/{node}/watch ----

    fn watch(call: Call) Failure!Reply {
        const ctx = call.ctx;
        try call.require_method("GET");
        try call.no_more();
        const numbers = try query_numbers(ctx, call.query);
        const from = numbers.from orelse
            return bad_request(ctx, "from", "is required: the revision to resume from");
        if (from == 0) return bad_request(ctx, "from", "must be at least 1");
        const timeout = numbers.timeout orelse constants.api_watch_timeout_ms_max;
        if (timeout > constants.api_watch_timeout_ms_max) {
            return bad_request(ctx, "timeout", "must be at most 25000");
        }
        const head = ctx.store.status(ctx.diag) catch return propagate(ctx);
        const options: store.WatchOptions = .{ .prefix = watch_prefixes[0], .from_revision = from };
        var open = ctx.store.watch(options, ctx.diag) catch return propagate(ctx);
        defer open.close();
        var bookmark = open.delivered;
        var changed = false;
        for (0..watch_batches_max) |_| {
            if (bookmark >= head.revision) break;
            const batch = open.next(ctx.arena, 0, ctx.diag) catch return propagate(ctx);
            bookmark = batch.revision;
            if (batch.events.len > 0) {
                changed = true;
                break;
            }
        }
        var answer = try reply(ctx, .{ .revision = bookmark, .changed = changed });
        if (!changed) {
            if (call.hold) {
                if (timeout > 0) {
                    answer.hold_ms = @intCast(timeout);
                    answer.hold_prefixes = &watch_prefixes;
                }
            }
        }
        return answer;
    }
};

/// Batches one watch request reads before it answers; each is at most `store_watch_batch_max`
/// events, and a store that has this many unread batches has changed.
const watch_batches_max: u32 = 64;
const node_text_bytes_max: u32 = 128;
const node_labels_max: u32 = 8;

// ---- Bodies and replies ------------------------------------------------------------------------

const RegisterBody = struct {
    lease: u64,
    capacity: records.Requests,
    agent_version: []const u8 = "",
    address: []const u8 = "",
    labels: []const []const u8 = &.{},
};

const LeaseBody = struct { ttl_ms: u32 };

const ObservedPut = struct { key: []const u8, value: records.Observed };

const ObservedBody = struct {
    puts: []const ObservedPut = &.{},
    deletes: []const []const u8 = &.{},
};

/// A key and its record, in the shape of `GET /v1/list`'s `kvs`.
fn Item(comptime T: type) type {
    return struct {
        key: []const u8,
        value: T,
        create_revision: u64,
        mod_revision: u64,
        lease: u64,
    };
}

fn item_of(comptime T: type, entry: controller.Entry(T)) Item(T) {
    return .{
        .key = entry.kv.key,
        .value = entry.rec,
        .create_revision = entry.kv.create_revision,
        .mod_revision = entry.kv.mod_revision,
        .lease = entry.kv.lease,
    };
}

/// Every reply of this file is one of a few anonymous structs; this writes it as compact JSON.
fn reply(ctx: *const Context, value: anytype) Failure!Reply {
    const options: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };
    const body = std.json.Stringify.valueAlloc(ctx.arena, value, options) catch
        return no_memory(ctx);
    if (body.len > constants.api_response_bytes_max) return no_memory(ctx);
    return .{ .body = body };
}

fn parse_body(comptime T: type, ctx: *const Context, body: []const u8) Failure!T {
    if (body.len == 0) return bad_request(ctx, "body", "is required: a JSON object");
    if (body.len > constants.api_request_bytes_max) {
        return bad_request(ctx, "body", "is larger than 65536 bytes");
    }
    return std.json.parseFromSliceLeaky(T, ctx.arena, body, .{}) catch |err| {
        if (err == error.OutOfMemory) return no_memory(ctx);
        return bad_request(ctx, "body", "is not what this endpoint takes: see docs/api.md");
    };
}

fn check_text(
    ctx: *const Context,
    what: []const u8,
    text: []const u8,
    bytes_max: u32,
) Failure!void {
    if (text.len > bytes_max) return bad_request(ctx, what, "is too long");
    for (text) |byte| {
        if (!text_util.is_printable(byte)) {
            return bad_request(ctx, what, "may hold printable ASCII");
        }
    }
}

fn no_duplicates(ctx: *const Context, ops: []const store.Op) Failure!void {
    assert(ops.len <= constants.agent_report_ops_max);
    for (ops, 0..) |first, index| {
        for (ops[index + 1 ..]) |second| {
            if (!std.mem.eql(u8, store.op_key(first), store.op_key(second))) continue;
            return bad_request(ctx, "body", "names a key more than once");
        }
    }
}

// ---- The query string: `from` and `timeout` only ----------------------------------------------

const Numbers = struct { from: ?u64 = null, timeout: ?u64 = null };

fn no_query(ctx: *const Context, text: []const u8) Failure!void {
    if (text.len == 0) return;
    return bad_request(ctx, "query", "this endpoint takes no parameters");
}

fn query_numbers(ctx: *const Context, text: []const u8) Failure!Numbers {
    var numbers: Numbers = .{};
    var pairs = std.mem.splitScalar(u8, text, '&');
    while (pairs.next()) |pair| {
        if (pair.len == 0) continue;
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse
            return bad_request(ctx, "query", "has a parameter without a value");
        const name = pair[0..equals];
        const value = std.fmt.parseInt(u64, pair[equals + 1 ..], 10) catch
            return bad_request(ctx, name, "is not a number");
        const slot = number_slot(&numbers, name) orelse
            return bad_request(ctx, name, "this endpoint takes no such parameter");
        if (slot.* != null) return bad_request(ctx, name, "may be given only once");
        slot.* = value;
    }
    return numbers;
}

fn number_slot(numbers: *Numbers, name: []const u8) ?*?u64 {
    if (std.mem.eql(u8, name, "from")) return &numbers.from;
    if (std.mem.eql(u8, name, "timeout")) return &numbers.timeout;
    return null;
}

// ---- Failures ----------------------------------------------------------------------------------

fn bad_request(ctx: *const Context, what: []const u8, problem: []const u8) Failure {
    assert(ctx.diag.code == null);
    ctx.diag.raise(.E0104);
    ctx.diag.cause("{s}: {s}", .{ what, problem });
    ctx.diag.fix(.{ .sentence = "see docs/api.md, \"Agent endpoints\", for the endpoint's shape" });
    return error.Failed;
}

fn no_such(ctx: *const Context, path: []const u8) Failure {
    assert(ctx.diag.code == null);
    ctx.diag.raise(.E0101);
    ctx.diag.cause("the API serves nothing at {s}", .{path});
    ctx.diag.fix(.{ .sentence = "the agent's endpoints are under /v1/agent/nodes/{node}/" });
    return error.Failed;
}

fn no_memory(ctx: *const Context) Failure {
    if (ctx.diag.code == null) {
        ctx.diag.raise(.E0207);
        ctx.diag.cause("the memory set aside for this request ran out", .{});
        ctx.diag.fix(.{ .sentence = "report fewer records at once" });
    }
    return error.Failed;
}

fn too_many(ctx: *const Context, what: []const u8) Failure {
    assert(ctx.diag.code == null);
    ctx.diag.raise(.E0302);
    ctx.diag.cause("this node has more than {d} {s}", .{ constants.agent_node_replicas_max, what });
    ctx.diag.fix(.{ .sentence = "delete services that are no longer needed" });
    return error.Failed;
}

/// A call below the API failed; by the contracts it left its diagnostic. If it did not, that is
/// our bug and is reported as one.
fn propagate(ctx: *const Context) Failure {
    if (ctx.diag.code == null) {
        ctx.diag.raise(.B0001);
        ctx.diag.cause("a call failed without saying why", .{});
    }
    return error.Failed;
}
