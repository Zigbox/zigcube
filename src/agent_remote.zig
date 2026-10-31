//! `RemoteStore`: the `Store` the node agent sees, implemented over the agent endpoints of
//! docs/api.md. Shell code: it speaks HTTP. The agent core (`agent.zig`) is written against
//! `Store` and makes only a few kinds of call; each is one request here, so the core is the same
//! code on this side of HTTP as in the simulation, and "the shell waits, the core decides" holds.
//!
//!   lease_grant, lease_keepalive     POST .../lease, POST .../lease/{id}/keepalive
//!   txn: one put of /nodes/<node>    PUT  /v1/agent/nodes/{node}
//!   txn: puts and deletes under
//!        /observed/<node>/           POST .../observed
//!   list /replicas/                  GET  .../replicas   (this node's, with env values)
//!   list /observed/<node>/           GET  .../observed
//!
//! Anything else (`get`, `watch`, `status`, a transaction with compares) is not something the
//! agent does; it is a bug in the adapter's caller, reported as one (ZC-B0001) rather than
//! answered wrongly.
//!
//! The wait between steps is `watch_once`, which is not part of `Store`: it asks the server
//! whether a replica changed since the revision of the last list, and holds up to the time given.
//!
//! The server's `ZC-E0205` (the lease is gone) becomes `error.LeaseNotFound`, because the agent
//! core grants a new lease on exactly that error. Every other refusal is ZC-E0504 with the
//! server's own diagnostic in the cause lines.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const diag_mod = @import("diag.zig");
const failures = @import("store_failures.zig");
const http = @import("agent_http.zig");
const records = @import("records.zig");
const store = @import("store.zig");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;
const Json = std.json.Value;

pub const RemoteStore = struct {
    gpa: Allocator,
    client: http.Client,
    /// The node's name, borrowed: it must outlive the store.
    node: []const u8,
    /// Where the next `watch_once` resumes: the revision of the last replica list, plus one.
    /// 0 until the first list, which makes the first watch answer "changed" at once.
    watch_from: store.Revision,

    const vtable: store.Store.VTable = .{
        .status = status_impl,
        .get = get_impl,
        .list = list_impl,
        .txn = txn_impl,
        .watch = watch_impl,
        .lease_grant = lease_grant_impl,
        .lease_keepalive = lease_keepalive_impl,
        .lease_revoke = lease_revoke_impl,
        .lease_list = lease_list_impl,
        .expire_leases = expire_leases_impl,
        .compact = compact_impl,
        .hash_at = hash_at_impl,
    };

    pub fn init(gpa: Allocator, client: http.Client, node: []const u8) RemoteStore {
        assert(records.name_problem(node, constants.node_name_bytes_max) == null);
        return .{ .gpa = gpa, .client = client, .node = node, .watch_from = 0 };
    }

    pub fn interface(remote: *RemoteStore) store.Store {
        return .{ .context = remote, .vtable = &vtable };
    }

    fn from(context: *anyopaque) *RemoteStore {
        return @ptrCast(@alignCast(context));
    }

    // ---- The wait ----

    /// True if a replica changed since the last list (or there has been no list, or the server
    /// cannot say), after holding up to `hold_ms` if none had. Failures are for the caller to
    /// report; the next step reads the truth either way.
    pub fn watch_once(remote: *RemoteStore, hold_ms: u32, diag: *Diag) store.Error!bool {
        assert(diag.code == null);
        assert(hold_ms <= constants.api_watch_timeout_ms_max);
        if (remote.watch_from == 0) return true;
        var arena_state = std.heap.ArenaAllocator.init(remote.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const target = std.fmt.allocPrint(
            arena,
            "/v1/agent/nodes/{s}/watch?from={d}&timeout={d}",
            .{ remote.node, remote.watch_from, hold_ms },
        ) catch return failures.no_memory(diag);
        const reply = try remote.exchange(arena, .{
            .method = "GET",
            .target = target,
            .hold_ms = hold_ms,
        }, diag);
        if (reply.status != 200) {
            // Behind the compaction point or ahead of the store: the list will say where we are.
            const code = refusal_code(arena, reply.body);
            if (code) |text| {
                if (resync_code(text)) {
                    remote.watch_from = 0;
                    return true;
                }
            }
            return refused(arena, reply, diag);
        }
        const Answer = struct { revision: u64, changed: bool };
        const answer = try parse(Answer, arena, reply.body, diag);
        if (!answer.changed) remote.watch_from = @max(remote.watch_from, answer.revision + 1);
        return answer.changed;
    }

    // ---- Leases ----

    fn lease_grant_impl(context: *anyopaque, ttl_ms: u32, diag: *Diag) store.Error!store.Lease {
        const remote = from(context);
        var arena_state = std.heap.ArenaAllocator.init(remote.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const target = try remote.path(arena, "/lease", diag);
        const body = try encode(arena, .{ .ttl_ms = ttl_ms }, diag);
        const reply = try remote.exchange(
            arena,
            .{ .method = "POST", .target = target, .body = body },
            diag,
        );
        if (reply.status != 200) return refused(arena, reply, diag);
        return parse_lease(arena, reply.body, diag);
    }

    fn lease_keepalive_impl(
        context: *anyopaque,
        id: store.LeaseId,
        diag: *Diag,
    ) store.Error!store.Lease {
        const remote = from(context);
        var arena_state = std.heap.ArenaAllocator.init(remote.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const suffix = std.fmt.allocPrint(arena, "/lease/{d}/keepalive", .{id}) catch
            return failures.no_memory(diag);
        const target = try remote.path(arena, suffix, diag);
        const reply = try remote.exchange(arena, .{ .method = "POST", .target = target }, diag);
        if (reply.status != 200) {
            const code = refusal_code(arena, reply.body);
            if (code) |text| {
                if (std.mem.eql(u8, text, "ZC-E0205")) return failures.lease_not_found(diag, id);
            }
            return refused(arena, reply, diag);
        }
        const lease = try parse_lease(arena, reply.body, diag);
        if (lease.id != id) return bad(diag, "the server renewed a different lease");
        return lease;
    }

    fn parse_lease(arena: Allocator, body: []const u8, diag: *Diag) store.Error!store.Lease {
        const Answer = struct { lease: struct { id: u64, ttl_ms: u32 } };
        const answer = try parse(Answer, arena, body, diag);
        if (answer.lease.id == store.lease_none) {
            return bad(diag, "the server granted lease 0");
        }
        return .{ .id = answer.lease.id, .ttl_ms = answer.lease.ttl_ms };
    }

    // ---- Lists ----

    fn list_impl(
        context: *anyopaque,
        arena: Allocator,
        options: store.ListOptions,
        diag: *Diag,
    ) store.Error!store.ListResult {
        const remote = from(context);
        assert(options.continue_after == null); // The reply is never paged: see agent_api.zig.
        assert(!options.reverse);
        const observed = records.observed_prefix(remote.node);
        const is_replicas = std.mem.eql(u8, options.prefix, records.prefix_replicas);
        const is_observed = std.mem.eql(u8, options.prefix, observed.slice());
        if (!is_replicas) {
            if (!is_observed) {
                return unsupported(diag, "a list of anything but the node's replicas and records");
            }
        }
        const suffix: []const u8 = if (is_replicas) "/replicas" else "/observed";
        const target = try remote.path(arena, suffix, diag);
        const reply = try remote.exchange(arena, .{ .method = "GET", .target = target }, diag);
        if (reply.status != 200) return refused(arena, reply, diag);
        const result = try list_result(arena, reply.body, options.limit, diag);
        if (std.mem.eql(u8, suffix, "/replicas")) remote.watch_from = result.revision + 1;
        return result;
    }

    const KvJson = struct {
        key: []const u8,
        value: Json,
        create_revision: u64 = 0,
        mod_revision: u64,
        lease: u64 = 0,
    };

    fn list_result(
        arena: Allocator,
        body: []const u8,
        limit: u32,
        diag: *Diag,
    ) store.Error!store.ListResult {
        const Answer = struct { revision: u64, kvs: []const KvJson };
        const answer = try parse(Answer, arena, body, diag);
        if (answer.kvs.len > limit) {
            return bad(diag, "the server listed more records than were asked for");
        }
        const kvs = arena.alloc(
            store.KeyValue,
            answer.kvs.len,
        ) catch return failures.no_memory(diag);
        for (answer.kvs, kvs) |item, *slot| {
            const invalid = "the server listed a record that is not valid";
            if (store.key_problem(item.key) != null) return bad(diag, invalid);
            if (item.mod_revision > answer.revision) return bad(diag, invalid);
            const value = std.json.Stringify.valueAlloc(arena, item.value, .{}) catch
                return failures.no_memory(diag);
            slot.* = .{
                .key = item.key,
                .value = value,
                .create_revision = item.create_revision,
                .mod_revision = item.mod_revision,
                .lease = item.lease,
            };
        }
        return .{ .kvs = kvs, .revision = answer.revision, .continue_after = null };
    }

    // ---- Transactions ----

    fn txn_impl(
        context: *anyopaque,
        request: store.TxnRequest,
        diag: *Diag,
    ) store.Error!store.TxnResult {
        const remote = from(context);
        if (request.compares.len > 0) return unsupported(diag, "a transaction with compares");
        if (request.on_failure.len > 0) return unsupported(
            diag,
            "a transaction with a failure branch",
        );
        assert(request.on_success.len > 0);
        var arena_state = std.heap.ArenaAllocator.init(remote.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const node_key = records.node_key(remote.node);
        const first = store.op_key(request.on_success[0]);
        const sent: http.Request = if (std.mem.eql(u8, first, node_key.slice()))
            try remote.registration(arena, request.on_success, diag)
        else
            try remote.report(arena, request.on_success, diag);
        const reply = try remote.exchange(arena, sent, diag);
        if (reply.status != 200) return refused(arena, reply, diag);
        const Answer = struct { revision: u64 };
        const answer = try parse(Answer, arena, reply.body, diag);
        return .{ .succeeded = true, .revision = answer.revision };
    }

    /// `PUT /v1/agent/nodes/{node}`: the one put of `/nodes/<node>` on a lease.
    fn registration(
        remote: *RemoteStore,
        arena: Allocator,
        ops: []const store.Op,
        diag: *Diag,
    ) store.Error!http.Request {
        if (ops.len != 1) return unsupported(diag, "a registration with other operations");
        const put = switch (ops[0]) {
            .put => |value| value,
            .delete => return unsupported(diag, "the delete of the node's registration"),
        };
        if (put.lease == store.lease_none) return unsupported(diag, "a registration with no lease");
        const node = std.json.parseFromSliceLeaky(records.Node, arena, put.value, .{
            .ignore_unknown_fields = true,
        }) catch return unsupported(diag, "a registration that is not a node record");
        const body = try encode(arena, .{
            .lease = put.lease,
            .capacity = node.capacity,
            .agent_version = node.agent_version,
            .address = node.address,
            .labels = node.labels,
        }, diag);
        const target = try remote.path(arena, "", diag);
        return .{ .method = "PUT", .target = target, .body = body };
    }

    /// `POST /v1/agent/nodes/{node}/observed`: puts and deletes of the node's observed records.
    fn report(
        remote: *RemoteStore,
        arena: Allocator,
        ops: []const store.Op,
        diag: *Diag,
    ) store.Error!http.Request {
        const prefix = records.observed_prefix(remote.node);
        var out: std.Io.Writer.Allocating = .init(arena);
        var json: std.json.Stringify = .{ .writer = &out.writer };
        json.beginObject() catch return failures.no_memory(diag);
        json.objectField("puts") catch return failures.no_memory(diag);
        json.beginArray() catch return failures.no_memory(diag);
        for (ops) |op| {
            if (!std.mem.startsWith(u8, store.op_key(op), prefix.slice())) {
                return unsupported(diag, "a write outside the node's observed records");
            }
            switch (op) {
                .put => |put| try write_put(&json, put, diag),
                .delete => {},
            }
        }
        json.endArray() catch return failures.no_memory(diag);
        json.objectField("deletes") catch return failures.no_memory(diag);
        json.beginArray() catch return failures.no_memory(diag);
        for (ops) |op| {
            switch (op) {
                .put => {},
                .delete => |key| json.write(key) catch return failures.no_memory(diag),
            }
        }
        json.endArray() catch return failures.no_memory(diag);
        json.endObject() catch return failures.no_memory(diag);
        const body = out.toOwnedSlice() catch return failures.no_memory(diag);
        const target = try remote.path(arena, "/observed", diag);
        return .{ .method = "POST", .target = target, .body = body };
    }

    fn write_put(json: *std.json.Stringify, put: store.Put, diag: *Diag) store.Error!void {
        json.beginObject() catch return failures.no_memory(diag);
        json.objectField("key") catch return failures.no_memory(diag);
        json.write(put.key) catch return failures.no_memory(diag);
        json.objectField("value") catch return failures.no_memory(diag);
        // The agent encoded the record itself, so the bytes are JSON; they go in as they are.
        json.beginWriteRaw() catch return failures.no_memory(diag);
        json.writer.writeAll(put.value) catch return failures.no_memory(diag);
        json.endWriteRaw();
        json.endObject() catch return failures.no_memory(diag);
    }

    // ---- What the agent never asks ----

    fn status_impl(context: *anyopaque, diag: *Diag) store.Error!store.Status {
        _ = context;
        return unsupported(diag, "status");
    }

    fn get_impl(
        context: *anyopaque,
        arena: Allocator,
        key: []const u8,
        at_revision: ?store.Revision,
        diag: *Diag,
    ) store.Error!store.GetResult {
        _ = context;
        _ = arena;
        _ = key;
        _ = at_revision;
        return unsupported(diag, "get");
    }

    fn watch_impl(
        context: *anyopaque,
        options: store.WatchOptions,
        diag: *Diag,
    ) store.Error!store.Watch {
        _ = context;
        _ = options;
        return unsupported(diag, "watch (the agent uses watch_once)");
    }

    fn lease_revoke_impl(
        context: *anyopaque,
        id: store.LeaseId,
        diag: *Diag,
    ) store.Error!store.Revision {
        _ = context;
        _ = id;
        return unsupported(diag, "lease_revoke");
    }

    fn lease_list_impl(
        context: *anyopaque,
        arena: Allocator,
        diag: *Diag,
    ) store.Error![]const store.LeaseInfo {
        _ = context;
        _ = arena;
        return unsupported(diag, "lease_list");
    }

    fn expire_leases_impl(context: *anyopaque, diag: *Diag) store.Error!u32 {
        _ = context;
        return unsupported(diag, "expire_leases");
    }

    fn compact_impl(context: *anyopaque, revision: store.Revision, diag: *Diag) store.Error!void {
        _ = context;
        _ = revision;
        return unsupported(diag, "compact");
    }

    fn hash_at_impl(
        context: *anyopaque,
        revision: store.Revision,
        diag: *Diag,
    ) store.Error!store.Hash {
        _ = context;
        _ = revision;
        return unsupported(diag, "hash_at");
    }

    // ---- Requests and replies ----

    fn exchange(
        remote: *RemoteStore,
        arena: Allocator,
        request: http.Request,
        diag: *Diag,
    ) store.Error!http.Reply {
        return remote.client.call(arena, request, diag) catch |err| switch (err) {
            error.OutOfMemory => failures.no_memory(diag),
            error.Unreachable, error.BadReply => error.BackendFailed,
        };
    }

    /// "/v1/agent/nodes/<node>" and `suffix`.
    fn path(
        remote: *RemoteStore,
        arena: Allocator,
        suffix: []const u8,
        diag: *Diag,
    ) store.Error![]const u8 {
        return std.fmt.allocPrint(arena, "/v1/agent/nodes/{s}{s}", .{ remote.node, suffix }) catch
            failures.no_memory(diag);
    }
};

/// The codes that mean "your revision is no use: list again" (compacted, or ahead of the store).
fn resync_code(text: []const u8) bool {
    if (std.mem.eql(u8, text, "ZC-E0203")) return true;
    return std.mem.eql(u8, text, "ZC-E0204");
}

// ---- Parsing and failures ----------------------------------------------------------------------

fn encode(arena: Allocator, value: anytype, diag: *Diag) store.Error![]const u8 {
    return std.json.Stringify.valueAlloc(arena, value, .{}) catch failures.no_memory(diag);
}

fn parse(comptime T: type, arena: Allocator, body: []const u8, diag: *Diag) store.Error!T {
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    return std.json.parseFromSliceLeaky(T, arena, body, options) catch |err| {
        if (err == error.OutOfMemory) return failures.no_memory(diag);
        return bad(diag, "the reply is not what the agent endpoints send");
    };
}

const Refusal = struct {
    request_id: []const u8 = "",
    diagnostics: []const struct {
        code: []const u8,
        summary: []const u8 = "",
        causes: []const []const u8 = &.{},
    } = &.{},
};

/// The code of the first diagnostic in an error body, if it has one.
fn refusal_code(arena: Allocator, body: []const u8) ?[]const u8 {
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    const parsed = std.json.parseFromSliceLeaky(Refusal, arena, body, options) catch return null;
    if (parsed.diagnostics.len == 0) return null;
    return parsed.diagnostics[0].code;
}

/// ZC-E0504 carrying the server's own diagnostic: its code and summary, and its innermost cause.
fn refused(arena: Allocator, reply: http.Reply, diag: *Diag) store.Error {
    assert(diag.code == null);
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    const parsed = std.json.parseFromSliceLeaky(Refusal, arena, reply.body, options) catch
        Refusal{};
    diag.raise(.E0504);
    if (parsed.diagnostics.len == 0) {
        diag.cause("zcube-server answered {d} with no diagnostic", .{reply.status});
    } else {
        const first = parsed.diagnostics[0];
        diag.cause(
            "zcube-server answered {d}: {s} ({s})",
            .{ reply.status, first.summary, first.code },
        );
        if (first.causes.len > 0) diag.cause("{s}", .{first.causes[first.causes.len - 1]});
    }
    if (parsed.request_id.len > 0) diag.context("req", "{s}", .{parsed.request_id});
    diag.fix(.{ .sentence = "look at the server's log for this request, or restart the server" });
    return error.BackendFailed;
}

/// ZC-E0504 for a reply that cannot be right.
fn bad(diag: *Diag, problem: []const u8) store.Error {
    http.raise_bad_reply(diag, problem);
    return error.BackendFailed;
}

fn unsupported(diag: *Diag, what: []const u8) store.Error {
    assert(diag.code == null);
    diag.raise(.B0001);
    diag.cause("the agent asked its store for {s}, which it does not offer", .{what});
    return error.BackendFailed;
}
