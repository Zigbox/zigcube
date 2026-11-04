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
//!   GET  /v1/agent/nodes/{node}/assigned               the node's assignments, as stored
//!   GET  /v1/agent/nodes/{node}/observed               what the node has reported
//!   POST /v1/agent/nodes/{node}/observed               one transaction of puts and deletes
//!   PUT  /v1/agent/nodes/{node}/store                  the node's image summary (advisory)
//!   GET  /v1/agent/nodes/{node}/watch?from=&timeout=   "something changed", a long poll
//!   POST /v1/agent/nodes/{node}/credential             a peer credential for the node's key
//!
//! **Every answer but the credential's carries `chain`**: `{"revision": R, "hash": "<hex>"}`,
//! the store's `status`
//! taken after the endpoint's work (the watch: the head it answered at). Every endpoint takes
//! `known=K`, the revision the agent remembers; when `K <= R` the pair adds `known_hash`, the
//! store's hash at `K` (left out on `NoHash`). The agent refuses an answer from behind with them
//! (`agent_client.zig`, "Nothing from behind"); the server only reports. `verified` says whether
//! the server keeps the store's pair across its own restarts (`Api.pair_kept`): false for a
//! memory store, which starts empty with every start, and then the agent keeps no pair either.
//! The write endpoints take the pair from their own transaction when it wrote (`hash`).
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
const compare_sets = @import("compare_sets.zig");
const controller = @import("controller.zig");
const records = @import("records.zig");
const store = @import("store.zig");
const writers = @import("writers.zig");
const text_util = @import("text.zig");

const Context = controller.Context;
const peer = @import("peer.zig");
const peer_ca = @import("peer_ca.zig");

/// The route failed and `ctx.diag` says why. Same set as `api.zig`'s, so `try` passes it up.
pub const Failure = error{Failed};

/// A reply that is not yet a `Response`: the same fields as `api.zig`'s.
pub const Reply = struct {
    body: []const u8,
    hold_ms: u32 = 0,
    hold_prefixes: []const []const u8 = &.{},
};

/// The keys whose change ends a held watch: this node's assignments, `/assigned/<node>/`
/// (authority.md §2), and nothing else. An agent reconciles by level: it lists its assignments
/// and joins each replica record. A replica record is written once and removed, never changed in
/// place (the replica controller replaces a replica rather than editing it), and the scheduler
/// deletes the assignment of a replica that is gone, so every change an agent must act on is a
/// change of its own `/assigned/<node>/`.
pub fn watch_prefixes(ctx: *const Context, node: []const u8) Failure![]const []const u8 {
    const key = records.assigned_prefix(node);
    const prefixes = ctx.arena.alloc([]const u8, 1) catch return no_memory(ctx);
    prefixes[0] = ctx.arena.dupe(u8, key.slice()) catch return no_memory(ctx);
    assert(prefixes.len == 1);
    assert(prefixes[0].len > node.len);
    return prefixes;
}

const Parts = std.mem.SplitIterator(u8, .scalar);

/// Routes one request under `/v1/agent/`. `parts` is positioned after "agent".
/// The largest request body the agent endpoint at `path` takes: the summary's is the hex of the
/// largest summary, every other agent request is `agent_request_bytes_max`.
pub fn body_bytes_max(path: []const u8) u32 {
    const prefix = "/v1/agent/nodes/";
    if (!std.mem.startsWith(u8, path, prefix)) return constants.agent_request_bytes_max;
    const rest = path[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse
        return constants.agent_request_bytes_max;
    if (std.mem.eql(u8, rest[slash..], "/credential")) return constants.peer_join_request_bytes_max;
    if (!std.mem.eql(u8, rest[slash..], "/store")) return constants.agent_request_bytes_max;
    return constants.summary_request_bytes_max;
}

pub fn route(
    ctx: *const Context,
    method: []const u8,
    parts: *Parts,
    query: []const u8,
    body: []const u8,
    hold: bool,
    lease_ttl_ms: u32,
    pair_kept: bool,
    ca: ?*const peer_ca.Ca,
) Failure!Reply {
    assert(ctx.diag.code == null);
    const nodes = parts.next() orelse return no_such(ctx, "/v1/agent");
    if (!std.mem.eql(u8, nodes, "nodes")) return no_such(ctx, "/v1/agent/");
    const node = parts.next() orelse return no_such(ctx, "/v1/agent/nodes");
    if (records.name_problem(node, constants.node_name_bytes_max) != null) {
        return bad_request(ctx, "node", "is not a valid node name");
    }
    const numbers = try query_numbers(ctx, query);
    const call: Call = .{
        .ctx = ctx,
        .node = node,
        .method = method,
        .numbers = numbers,
        .body = body,
        .hold = hold,
        .pair_kept = pair_kept,
        .parts = parts,
        .lease_ttl_ms = lease_ttl_ms,
        .ca = ca,
    };
    const what = parts.next() orelse return call.register();
    if (std.mem.eql(u8, what, "lease")) return call.lease();
    if (std.mem.eql(u8, what, "replicas")) return call.replicas();
    if (std.mem.eql(u8, what, "assigned")) return call.assigned();
    if (std.mem.eql(u8, what, "observed")) return call.observed();
    if (std.mem.eql(u8, what, "store")) return call.summary();
    if (std.mem.eql(u8, what, "watch")) return call.watch();
    if (std.mem.eql(u8, what, "credential")) return call.credential();
    return no_such(ctx, "/v1/agent/nodes/<node>/<that>");
}

const Call = struct {
    ctx: *const Context,
    node: []const u8,
    method: []const u8,
    numbers: Numbers,
    body: []const u8,
    hold: bool,
    pair_kept: bool,
    parts: *Parts,
    /// The ttl of the leases this server grants: the agent learns it from the grant.
    lease_ttl_ms: u32,
    /// The cluster CA, null where the server has none (the simulation).
    ca: ?*const peer_ca.Ca,

    fn require_method(call: Call, wanted: []const u8) Failure!void {
        if (std.mem.eql(u8, call.method, wanted)) return;
        const problem = "this endpoint answers a different method: see docs/api.md";
        return bad_request(call.ctx, "method", problem);
    }

    fn no_more(call: Call) Failure!void {
        if (call.parts.next() != null) return no_such(call.ctx, "that path");
    }

    /// Every endpoint but the watch takes `known` alone.
    fn only_known(call: Call) Failure!void {
        if (call.numbers.from != null) return no_parameter(call.ctx, "from");
        if (call.numbers.timeout != null) return no_parameter(call.ctx, "timeout");
    }

    /// The pair the answer carries: the store's status, read after the endpoint did its work, so
    /// it is at least as new as anything else in the answer; and the hash at the agent's `known`
    /// revision when the store has one (docs/api.md, "The chain pair").
    ///
    /// Read after the work by a second call, the pair and what the work saw are two moments: a
    /// store that went back between them and forward again past what the agent remembers is not
    /// seen. The write endpoints close that window with `chain_written`; the leases (no
    /// transaction result) and a transaction that wrote nothing keep it.
    fn chain(call: Call) Failure!Chain {
        const head = call.ctx.store.status(call.ctx.diag) catch return propagate(call.ctx);
        return call.chain_of(head.revision, head.hash);
    }

    /// The pair of the revision a transaction wrote, from its own result: the same moment as the
    /// write. A transaction that wrote nothing (or a store that cannot say) has no hash: `status`.
    fn chain_written(call: Call, result: store.TxnResult) Failure!Chain {
        const hash = result.hash orelse return call.chain();
        return call.chain_of(result.revision, hash);
    }

    fn ca_id(call: Call) Failure!?[]const u8 {
        const ca = call.ca orelse return null;
        const id = peer.ca_key_id(ca.public());
        return std.fmt.allocPrint(call.ctx.arena, "{x}", .{&id}) catch no_memory(call.ctx);
    }

    fn chain_of(call: Call, revision: store.Revision, hash: store.Hash) Failure!Chain {
        const ctx = call.ctx;
        var result: Chain = .{
            .revision = revision,
            .hash = try hex(ctx, hash),
            .verified = call.pair_kept,
            .ca_key_id = try call.ca_id(),
        };
        const known = call.numbers.known orelse return result;
        // Above the store's revision there is no hash: the agent sees the lower revision and
        // refuses on that.
        if (known > revision) return result;
        if (known == revision) {
            result.known_hash = result.hash;
            return result;
        }
        const there = ctx.store.hash_at(known, ctx.diag) catch |err| {
            if (err != error.NoHash) return propagate(ctx);
            // Before the chain's start: left out, and the agent refuses it as unverifiable.
            ctx.diag.reset();
            return result;
        };
        result.known_hash = try hex(ctx, there);
        return result;
    }

    // ---- POST /v1/agent/nodes/{node}/credential ----

    /// Signs the node's peer key (docs/peer.md), for a node that is registered under the live
    /// lease the request names. It reads `/nodes/<node>` and writes no store key: the CA is not a
    /// store writer (authority.md), so there is no chain pair in the answer either. The API is
    /// unauthenticated, so this binds an honest node only: whoever can reach the port and read
    /// `/nodes/<node>` can name its lease.
    fn credential(call: Call) Failure!Reply {
        const ctx = call.ctx;
        try call.require_method("POST");
        try call.only_known();
        try call.no_more();
        const ca = call.ca orelse return no_such(ctx, "a peer credential: this server has no CA");
        const limits: BodyLimits = .{
            .bytes_max = constants.peer_join_request_bytes_max,
            .ignore_unknown_fields = false,
        };
        const input = try parse_body_up_to(CredentialBody, ctx, call.body, limits);
        var node_key: [32]u8 = undefined;
        const decoded = std.fmt.hexToBytes(&node_key, input.node_key) catch
            return bad_request(ctx, "node_key", "is not 64 hex digits");
        if (decoded.len != node_key.len) {
            return bad_request(ctx, "node_key", "is not 64 hex digits");
        }
        try call.registered_on(input.lease);
        const issued = ca.issue(call.node, node_key) catch |err| switch (err) {
            error.Removed => return removed(ctx, call.node),
            error.BadKey => return bad_request(ctx, "node_key", "is not an Ed25519 public key"),
        };
        const bytes = peer.encode(&issued);
        const ca_public = ca.public();
        return reply(ctx, .{
            .credential = std.fmt.allocPrint(ctx.arena, "{x}", .{&bytes}) catch
                return no_memory(ctx),
            .ca_public = std.fmt.allocPrint(ctx.arena, "{x}", .{&ca_public}) catch
                return no_memory(ctx),
            .not_before_ms = issued.not_before_ms,
            .not_after_ms = issued.not_after_ms,
        });
    }

    /// The node's record is on `lease`, and `lease` is not 0 (ZC-E0205 otherwise). A lease that
    /// ended deleted its keys, so a record on it is a live registration.
    fn registered_on(call: Call, lease_id: store.LeaseId) Failure!void {
        const ctx = call.ctx;
        if (lease_id == store.lease_none) return bad_request(ctx, "lease", "must not be 0");
        const key = records.node_key(call.node);
        const found = ctx.store.get(ctx.arena, key.slice(), null, ctx.diag) catch {
            return propagate(ctx);
        };
        const kv = found.kv orelse return not_registered(ctx, call.node, lease_id);
        if (kv.lease != lease_id) return not_registered(ctx, call.node, lease_id);
    }

    // ---- PUT /v1/agent/nodes/{node} ----

    fn register(call: Call) Failure!Reply {
        const ctx = call.ctx;
        try call.require_method("PUT");
        try call.only_known();
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
        const request: store.TxnRequest = .{ .on_success = &.{op} };
        const role: writers.Role = .{ .agent = call.node };
        const result = writers.txn(ctx.store, role, request, ctx.diag) catch
            return propagate(ctx);
        const pair = try call.chain_written(result);
        return reply(ctx, .{ .revision = result.revision, .chain = pair });
    }

    // ---- POST /v1/agent/nodes/{node}/lease[/{id}/keepalive] ----

    fn lease(call: Call) Failure!Reply {
        const ctx = call.ctx;
        try call.require_method("POST");
        try call.only_known();
        const id_text = call.parts.next() orelse return call.lease_grant();
        const keepalive = call.parts.next() orelse return no_such(ctx, "that path");
        if (!std.mem.eql(u8, keepalive, "keepalive")) return no_such(ctx, "that path");
        try call.no_more();
        const id = std.fmt.parseInt(u64, id_text, 10) catch
            return bad_request(ctx, "lease", "is not a number");
        if (id == store.lease_none) return bad_request(ctx, "lease", "must not be 0");
        const granted = ctx.store.lease_keepalive(id, ctx.diag) catch return propagate(ctx);
        const lease_reply = .{ .id = granted.id, .ttl_ms = granted.ttl_ms };
        return reply(ctx, .{ .lease = lease_reply, .chain = try call.chain() });
    }

    fn lease_grant(call: Call) Failure!Reply {
        const ctx = call.ctx;
        _ = try parse_body(LeaseBody, ctx, call.body); // The agent's ttl is a hint; ours stands.
        const granted = ctx.store.lease_grant(call.lease_ttl_ms, ctx.diag) catch
            return propagate(ctx);
        const lease_reply = .{ .id = granted.id, .ttl_ms = granted.ttl_ms };
        return reply(ctx, .{ .lease = lease_reply, .chain = try call.chain() });
    }

    // ---- GET /v1/agent/nodes/{node}/replicas ----

    fn replicas(call: Call) Failure!Reply {
        const ctx = call.ctx;
        try call.require_method("GET");
        try call.only_known();
        try call.no_more();
        const all = controller.list_all(
            records.Replica,
            ctx,
            records.prefix_replicas,
            null,
            constants.replicas_max,
        ) catch return propagate(ctx);
        const given = controller.list_all(
            records.Assigned,
            ctx,
            records.assigned_prefix(call.node).slice(),
            all.revision,
            constants.agent_node_replicas_max,
        ) catch return propagate(ctx);
        // The replicas the scheduler assigned to this node, in `/replicas` order. An assignment
        // whose replica is gone is not served, so the agent stops the container.
        var wanted: std.StringHashMapUnmanaged(void) = .empty;
        for (given.items) |entry| {
            wanted.put(ctx.arena, entry.rec.replica, {}) catch return no_memory(ctx);
        }
        var mine: std.ArrayList(Item(records.Replica)) = .empty;
        for (all.items) |entry| {
            if (!wanted.contains(entry.rec.id)) continue;
            mine.append(ctx.arena, item_of(records.Replica, entry)) catch return no_memory(ctx);
        }
        const pair = try call.chain();
        return reply(ctx, .{ .revision = all.revision, .kvs = mine.items, .chain = pair });
    }

    // ---- GET /v1/agent/nodes/{node}/assigned ----

    /// The node's assignments, as stored.
    fn assigned(call: Call) Failure!Reply {
        const ctx = call.ctx;
        try call.require_method("GET");
        try call.only_known();
        try call.no_more();
        const given = controller.list_all(
            records.Assigned,
            ctx,
            records.assigned_prefix(call.node).slice(),
            null,
            constants.agent_node_replicas_max,
        ) catch return propagate(ctx);
        const items = ctx.arena.alloc(Item(records.Assigned), given.items.len) catch
            return no_memory(ctx);
        for (given.items, items) |entry, *slot| slot.* = item_of(records.Assigned, entry);
        const pair = try call.chain();
        return reply(ctx, .{ .revision = given.revision, .kvs = items, .chain = pair });
    }

    // ---- GET and POST /v1/agent/nodes/{node}/observed ----

    fn observed(call: Call) Failure!Reply {
        const ctx = call.ctx;
        try call.only_known();
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
        const pair = try call.chain();
        return reply(ctx, .{ .revision = all.revision, .kvs = items, .chain = pair });
    }

    /// One transaction: the observed records to write and the replica ids whose records go.
    fn report(call: Call) Failure!Reply {
        const ctx = call.ctx;
        const input = try parse_body(ObservedBody, ctx, call.body);
        if (input.tenure == 0) return bad_request(ctx, "tenure", "is needed: it must not be 0");
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
        var tenure: compare_sets.Set = .{};
        compare_sets.observed_write(&tenure, call.node, input.tenure);
        const request: store.TxnRequest = .{
            .compares = tenure.compares(),
            .on_success = ops[0..count],
        };
        const role: writers.Role = .{ .agent = call.node };
        const result = writers.txn(ctx.store, role, request, ctx.diag) catch
            return propagate(ctx);
        if (!result.succeeded) return tenure_ended(ctx, call.node);
        const pair = try call.chain_written(result);
        return reply(ctx, .{ .revision = result.revision, .chain = pair });
    }

    // ---- PUT /v1/agent/nodes/{node}/store ----

    /// The node's image summary, on the lease the agent names, under its tenure. Advisory, so
    /// the checks are on shape and size, not on content.
    fn summary(call: Call) Failure!Reply {
        const ctx = call.ctx;
        try call.require_method("PUT");
        try call.only_known();
        try call.no_more();
        if (call.body.len > constants.summary_request_bytes_max) {
            return bad_request(ctx, "body", "is larger than a summary can be");
        }
        const input = try parse_body_up_to(SummaryBody, ctx, call.body, .{
            .bytes_max = constants.summary_request_bytes_max,
            .ignore_unknown_fields = true,
        });
        if (input.summary.v != 1) return bad_request(ctx, "summary.v", "must be 1");
        if (input.tenure == 0) return bad_request(ctx, "tenure", "is needed: it must not be 0");
        if (input.lease == store.lease_none) return bad_request(ctx, "lease", "must not be 0");
        if (!std.mem.eql(u8, input.summary.node, call.node)) {
            return bad_request(ctx, "summary", "is for another node");
        }
        if (input.summary.trees.len > constants.summary_trees_max) {
            return bad_request(ctx, "summary", "holds more trees than a summary may");
        }
        const value = records.encode(ctx.arena, input.summary, ctx.diag) catch
            return propagate(ctx);
        if (value.len > constants.store_value_bytes_max) {
            return bad_request(ctx, "summary", "is larger than a stored value may be");
        }
        try call.lease_matches(input.tenure, input.lease);
        const key = records.node_store_key(call.node);
        const put: store.Put = .{ .key = key.slice(), .value = value, .lease = input.lease };
        const op: store.Op = .{ .put = put };
        var tenure: compare_sets.Set = .{};
        compare_sets.observed_write(&tenure, call.node, input.tenure);
        const request: store.TxnRequest = .{ .compares = tenure.compares(), .on_success = &.{op} };
        const role: writers.Role = .{ .agent = call.node };
        const result = writers.txn(ctx.store, role, request, ctx.diag) catch
            return propagate(ctx);
        if (!result.succeeded) return tenure_ended(ctx, call.node);
        const pair = try call.chain_written(result);
        return reply(ctx, .{ .revision = result.revision, .chain = pair });
    }

    /// The summary rides the lease of the node's registration, which the tenure compare pins: a
    /// body that names another lease (or none) is refused, so it cannot attach the record to a
    /// lease that ends at another time.
    fn lease_matches(call: Call, tenure: u64, named: u64) Failure!void {
        const ctx = call.ctx;
        const key = records.node_key(call.node);
        const got = ctx.store.get(ctx.arena, key.slice(), null, ctx.diag) catch
            return propagate(ctx);
        const registered = got.kv orelse return tenure_ended(ctx, call.node);
        if (registered.mod_revision != tenure) return tenure_ended(ctx, call.node);
        if (registered.lease != named) {
            return bad_request(ctx, "lease", "is not the lease of this node's registration");
        }
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
        const numbers = call.numbers;
        const from = numbers.from orelse
            return bad_request(ctx, "from", "is required: the revision to resume from");
        if (from == 0) return bad_request(ctx, "from", "must be at least 1");
        const timeout = numbers.timeout orelse constants.api_watch_timeout_ms_max;
        if (timeout > constants.api_watch_timeout_ms_max) {
            return bad_request(ctx, "timeout", "must be at most 25000");
        }
        const head = ctx.store.status(ctx.diag) catch return propagate(ctx);
        // With nothing changed, the bookmark is the prefix's (the scan may stop
        // short of the head), so resuming from it skips no revision of the prefix.
        var bookmark: store.Revision = std.math.maxInt(store.Revision);
        var changed = false;
        const prefixes = try watch_prefixes(ctx, call.node);
        for (prefixes) |prefix| {
            const seen = try scan_watch(ctx, prefix, from, head.revision);
            bookmark = @min(bookmark, seen.bookmark);
            if (seen.changed) {
                bookmark = seen.bookmark;
                changed = true;
                break;
            }
        }
        // The head was read before the watch, after every earlier request of this agent.
        const pair = try call.chain_of(head.revision, head.hash);
        var answer = try reply(ctx, .{ .revision = bookmark, .changed = changed, .chain = pair });
        if (!changed) {
            if (call.hold) {
                if (timeout > 0) {
                    answer.hold_ms = @intCast(timeout);
                    answer.hold_prefixes = prefixes;
                }
            }
        }
        return answer;
    }
};

const Scan = struct { bookmark: store.Revision, changed: bool };

/// Reads the events of `prefix` from `from` up to `head`: whether there are any, and the
/// revision read up to.
fn scan_watch(
    ctx: *const Context,
    prefix: []const u8,
    from: u64,
    head: store.Revision,
) Failure!Scan {
    const options: store.WatchOptions = .{ .prefix = prefix, .from_revision = from };
    var open = ctx.store.watch(options, ctx.diag) catch return propagate(ctx);
    defer open.close();
    var bookmark = open.delivered;
    for (0..watch_batches_max) |_| {
        if (bookmark >= head) break;
        const batch = open.next(ctx.arena, 0, ctx.diag) catch return propagate(ctx);
        bookmark = batch.revision;
        if (batch.events.len > 0) return .{ .bookmark = bookmark, .changed = true };
    }
    return .{ .bookmark = bookmark, .changed = false };
}

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

const CredentialBody = struct { node_key: []const u8, lease: u64 };

const LeaseBody = struct { ttl_ms: u32 = 0 };

const ObservedPut = struct { key: []const u8, value: records.Observed };

/// The chain pair every answer carries (docs/api.md, "The chain pair"): hashes in lower-case hex.
const Chain = struct {
    revision: u64,
    hash: []const u8,
    known_hash: ?[]const u8 = null,
    /// False when the server does not keep this store's pair across its restarts.
    verified: bool,
    /// The cluster CA's key id (16 hex digits), when this server has a CA: the agent compares it
    /// with its credential's on every answer and joins again when it differs (docs/peer.md).
    ca_key_id: ?[]const u8 = null,
};

fn hex(ctx: *const Context, hash: store.Hash) Failure![]const u8 {
    return std.fmt.allocPrint(ctx.arena, "{x}", .{&hash}) catch no_memory(ctx);
}

const SummaryBody = struct {
    tenure: u64 = 0,
    lease: u64 = 0,
    summary: records.NodeStore,
};

const ObservedBody = struct {
    /// The revision of the registration the agent writes under (its tenure).
    tenure: u64 = 0,
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
    return parse_body_up_to(T, ctx, body, .{
        .bytes_max = constants.api_request_bytes_max,
        .ignore_unknown_fields = false,
    });
}

const BodyLimits = struct { bytes_max: u32, ignore_unknown_fields: bool };

fn parse_body_up_to(
    comptime T: type,
    ctx: *const Context,
    body: []const u8,
    limits: BodyLimits,
) Failure!T {
    if (body.len == 0) return bad_request(ctx, "body", "is required: a JSON object");
    if (body.len > limits.bytes_max) {
        return bad_request(ctx, "body", "is larger than this endpoint takes");
    }
    const options: std.json.ParseOptions = .{
        .ignore_unknown_fields = limits.ignore_unknown_fields,
    };
    return std.json.parseFromSliceLeaky(T, ctx.arena, body, options) catch |err| {
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

// ---- The query string: `known` everywhere, `from` and `timeout` for the watch -----------------

const Numbers = struct { from: ?u64 = null, timeout: ?u64 = null, known: ?u64 = null };

fn no_parameter(ctx: *const Context, name: []const u8) Failure {
    return bad_request(ctx, name, "this endpoint takes no such parameter");
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
    if (std.mem.eql(u8, name, "known")) return &numbers.known;
    return null;
}

// ---- Failures ----------------------------------------------------------------------------------

/// I2: the registration the agent wrote under is not the node's current one.
fn tenure_ended(ctx: *const Context, node: []const u8) Failure {
    assert(ctx.diag.code == null);
    ctx.diag.raise(.E0510);
    ctx.diag.cause("node {s} is not registered under the tenure this write names", .{node});
    ctx.diag.fix(.{ .sentence = "the agent stops its containers and registers the node again" });
    return error.Failed;
}

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

fn removed(ctx: *const Context, node: []const u8) Failure {
    assert(ctx.diag.code == null);
    ctx.diag.raise(.E0807);
    ctx.diag.cause("node {s} is on the server's list of removed nodes", .{node});
    ctx.diag.fix(.{ .sentence = "take the name out of the revoked file and restart zcube-server" });
    return error.Failed;
}

fn not_registered(ctx: *const Context, node: []const u8, lease_id: store.LeaseId) Failure {
    assert(ctx.diag.code == null);
    ctx.diag.raise(.E0205);
    ctx.diag.cause("node {s} is not registered under lease {d}", .{ node, lease_id });
    ctx.diag.cause("a peer credential is issued only to a registered node", .{});
    ctx.diag.fix(.{ .sentence = "the agent registers first and asks again by itself" });
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
