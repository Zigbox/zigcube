//! `RemoteStore`: the `Store` the node agent sees, implemented over the agent endpoints of
//! docs/api.md. Core code: it builds the requests and reads the replies, and hands the bytes to a
//! `Transport` (the network seam). The shell's transport is HTTP (`agent_remote.zig`); the
//! cluster simulation's is `sim_net.zig`. The agent core (`agent.zig`) is written against
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
//! **Nothing from behind** (C1 10b; docs/store-design.md, "Nothing acts on a store that went
//! backwards"). Every answer of the agent endpoints carries `chain`: the store's revision and
//! chain hash when the server answered, and, for the `known` revision every request sends (the
//! pair this store remembers), the store's hash at that revision. `exchange` checks it before
//! anything reads the answer: a lower revision, a different hash at the remembered revision, or
//! none at all (the store cannot say) is `ZC-E0215`, the server's own diagnostic worded for an
//! agent, and the call fails, so the agent core acts on nothing from that answer. The pair never
//! moves down, so the refusal lasts until an operator removes the agent's file. `hash_at` stays
//! unsupported: the check needs the hash at one revision, carried on the answer it guards, not a
//! second request that would check another moment.
//!
//! The pair lives in `AgentState` as `remembered` (`load` at start, `save` between steps, at most
//! every `verified_save_ms`, and once more at a clean stop; a copy that lags is safe, only
//! weaker), with the server address the agent was given (`--server`). A state directory from
//! before this file existed loads with nothing remembered; a pair saved for another address is
//! not compared (`Notice.server_changed`): the agent starts fresh. A store recreated at the same
//! address is not told apart from one that went back, and is refused the same way.
//!
//! **A server that keeps no pair.** An answer whose `chain` says `"verified": false` comes from a
//! server whose store does not outlive its restarts (a memory store), which the server itself
//! does not hold against it. The agent matches that: it neither refuses nor keeps a pair for such
//! a server, and forgets one it had (`Notice.unverified`, once).
//!
//! The server's `ZC-E0205` (the lease is gone) becomes `error.LeaseNotFound`, because the agent
//! core grants a new lease on exactly that error. Every other refusal is ZC-E0504 with the
//! server's own diagnostic in the cause lines.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const agent_state = @import("agent_state.zig");
const diag_mod = @import("diag.zig");
const failures = @import("store_failures.zig");
const records = @import("records.zig");
const store = @import("store.zig");
const verified = @import("store_verified.zig");

const Allocator = std.mem.Allocator;
const Diag = diag_mod.Diag;
const Json = std.json.Value;
const Pair = verified.Pair;

/// The agent's remembered pair, in its state directory.
pub const remembered_file = "remembered";
/// The longest server address the file keeps: an IPv6 address with a zone and a port fits.
pub const remembered_server_bytes_max: u32 = 96;
/// `{"v":2,"server":"<address>","revision":<u64>,"hash":"<64 hex>"}` and room to spare, with
/// every byte of the address escaped (six bytes each at most).
const remembered_bytes_max: u32 = 192 + 6 * remembered_server_bytes_max;
/// Version 1 had no `server`: its pair is kept and compared, for the address is unknown.
const remembered_version: u32 = 2;

/// News about the remembered pair for the person running the agent (`take_notice`).
pub const Notice = enum {
    /// The file's pair was saved for another server address: not compared, the agent starts
    /// fresh. Raised by `load`; `previous_server` names the old address.
    server_changed,
    /// The server keeps no pair for its store (`"verified": false`): the agent keeps none.
    unverified,
};

pub const Error = error{ Unreachable, BadReply, OutOfMemory };

pub const Request = struct {
    method: []const u8,
    /// Path and query: "/v1/agent/nodes/node1/replicas".
    target: []const u8,
    body: []const u8 = "",
    /// How long the server may hold the reply (a long poll), on top of the I/O timeout.
    hold_ms: u32 = 0,
};

pub const Reply = struct {
    status: u16,
    body: []const u8,
};

/// The network between an agent and the server: request bytes in, reply bytes out. `Unreachable`
/// and `BadReply` leave a diagnostic in `diag` (ZC-E0503, ZC-E0504). A reply may be lost after
/// the server acted on the request, so a caller that sees `Unreachable` cannot know whether a
/// write happened.
pub const Transport = struct {
    context: *anyopaque,
    call_fn: *const fn (
        context: *anyopaque,
        arena: Allocator,
        request: Request,
        diag: *Diag,
    ) Error!Reply,

    pub fn call(transport: Transport, arena: Allocator, request: Request, diag: *Diag) Error!Reply {
        assert(request.target.len > 0);
        assert(request.target[0] == '/');
        return transport.call_fn(transport.context, arena, request, diag);
    }
};

/// ZC-E0504 on `diag`, for a caller that returns an error of its own.
pub fn raise_bad_reply(diag: *Diag, problem: []const u8) void {
    assert(diag.code == null);
    diag.raise(.E0504);
    diag.cause("{s}", .{problem});
    diag.fix(.{ .sentence = "use the agent that came with the server" });
}

pub const RemoteStore = struct {
    gpa: Allocator,
    transport: Transport,
    /// The node's name, borrowed: it must outlive the store.
    node: []const u8,
    /// Where the next `watch_once` resumes: the revision of the last replica list, plus one.
    /// 0 until the first list, which makes the first watch answer "changed" at once.
    watch_from: store.Revision,
    /// The highest pair an answer carried (or the file held): never lowered.
    known: ?Pair = null,
    /// What the file is known to hold, and when it was written (`save`).
    saved: ?Pair = null,
    saved_ms: u64 = 0,
    /// The state directory as the person running the agent named it, for the fix line.
    state_dir: []const u8 = "<state dir>",
    /// The server address the agent was given, borrowed (`load`); saved with the pair.
    server: []const u8 = "",
    /// What to tell the person, taken by `take_notice`.
    notice: ?Notice = null,
    /// `Notice.unverified` is raised once per process.
    unverified_noted: bool = false,
    /// The address the file named, for `Notice.server_changed`.
    previous_server: [remembered_server_bytes_max]u8 = undefined,
    previous_server_len: u32 = 0,

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

    pub fn init(gpa: Allocator, transport: Transport, node: []const u8) RemoteStore {
        assert(records.name_problem(node, constants.node_name_bytes_max) == null);
        return .{ .gpa = gpa, .transport = transport, .node = node, .watch_from = 0 };
    }

    pub fn interface(remote: *RemoteStore) store.Store {
        return .{ .context = remote, .vtable = &vtable };
    }

    /// The news about the pair since the last call, if any.
    pub fn take_notice(remote: *RemoteStore) ?Notice {
        const notice = remote.notice;
        remote.notice = null;
        return notice;
    }

    /// For `Notice.server_changed`: the address the file named.
    pub fn previous_server_name(remote: *const RemoteStore) []const u8 {
        return remote.previous_server[0..remote.previous_server_len];
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
        const sent: Request = if (std.mem.eql(u8, first, node_key.slice()))
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
    ) store.Error!Request {
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
    ) store.Error!Request {
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

    /// One request with the remembered revision added, and its answer checked against it.
    fn exchange(
        remote: *RemoteStore,
        arena: Allocator,
        request: Request,
        diag: *Diag,
    ) store.Error!Reply {
        var sent = request;
        if (remote.known) |known| {
            const separator: u8 = if (std.mem.indexOfScalar(u8, request.target, '?') == null)
                '?'
            else
                '&';
            sent.target = std.fmt.allocPrint(arena, "{s}{c}known={d}", .{
                request.target, separator, known.revision,
            }) catch return failures.no_memory(diag);
        }
        const reply = remote.transport.call(arena, sent, diag) catch |err| switch (err) {
            error.OutOfMemory => return failures.no_memory(diag),
            error.Unreachable, error.BadReply => return error.BackendFailed,
        };
        // A refusal carries no pair and is not acted on; every answer that is, is checked.
        if (reply.status == 200) try remote.check(arena, reply.body, diag);
        return reply;
    }

    /// Refuses an answer from behind the remembered pair, else moves the pair up to it.
    fn check(
        remote: *RemoteStore,
        arena: Allocator,
        body: []const u8,
        diag: *Diag,
    ) store.Error!void {
        const ChainJson = struct {
            revision: u64,
            hash: []const u8,
            known_hash: ?[]const u8 = null,
            // Absent from the first 10b servers, which kept a pair for every store.
            verified: bool = true,
        };
        const Answer = struct { chain: ?ChainJson = null };
        const answer = try parse(Answer, arena, body, diag);
        const chain = answer.chain orelse
            return bad(diag, "the reply carries no chain pair: the server is older than the agent");
        const now: Pair = .{ .revision = chain.revision, .hash = try parse_hash(chain.hash, diag) };
        if (!chain.verified) return remote.forget_unverified();
        const known = remote.known orelse {
            remote.known = now;
            return;
        };
        try remote.compare(known, now, chain.known_hash, diag);
        assert(now.revision >= known.revision);
        if (now.revision > known.revision) remote.known = now;
    }

    /// The server does not hold its own store to the pair, so the agent does not either: it
    /// drops what it remembers (the file is rewritten by the first save once a pair is kept
    /// again) and says so once.
    fn forget_unverified(remote: *RemoteStore) void {
        remote.known = null;
        remote.saved = null;
        if (remote.unverified_noted) return;
        remote.unverified_noted = true;
        remote.notice = .unverified;
    }

    fn compare(
        remote: *const RemoteStore,
        known: Pair,
        now: Pair,
        known_hash: ?[]const u8,
        diag: *Diag,
    ) store.Error!void {
        var rollback: failures.Rollback = .{
            .remembered_revision = known.revision,
            .remembered_hash = known.hash,
            .now_revision = now.revision,
            .now_hash = now.hash,
            .agent_state_dir = remote.state_dir,
        };
        if (now.revision < known.revision) return failures.went_backwards(diag, rollback);
        const text = known_hash orelse {
            rollback.unverifiable = true;
            return failures.went_backwards(diag, rollback);
        };
        const there = try parse_hash(text, diag);
        if (!std.mem.eql(u8, &there, &known.hash)) {
            rollback.now_hash = there;
            return failures.went_backwards(diag, rollback);
        }
        // The same revision must be the same pair; `known_hash` already said so on an honest
        // server, and a server that contradicts itself is not believed either.
        if (now.revision == known.revision) {
            if (!std.mem.eql(u8, &now.hash, &known.hash)) {
                return failures.went_backwards(diag, rollback);
            }
        }
    }

    // ---- The remembered pair in the state directory ----

    /// Reads the pair the agent saved before it stopped. No file (a first start, or a state
    /// directory from before 10b) is nothing remembered; a file that does not parse is
    /// `ZC-E0216`, and the agent does not start on a guess.
    ///
    /// `server` is the address the agent was given, borrowed: it is saved with the pair, and a
    /// pair saved for another address is not loaded (`Notice.server_changed`). A version 1 file
    /// names no address and is loaded as it is.
    pub fn load(
        remote: *RemoteStore,
        state: agent_state.AgentState,
        state_dir: []const u8,
        server: []const u8,
        arena: Allocator,
        diag: *Diag,
    ) error{BackendFailed}!void {
        assert(diag.code == null);
        assert(remote.known == null);
        assert(server.len <= remembered_server_bytes_max);
        remote.state_dir = state_dir;
        remote.server = server;
        const text = state.read(arena, remembered_file) catch |err| switch (err) {
            error.Absent => return,
            else => return remote.unusable(diag, @errorName(err)),
        };
        const damaged = "it is not what the agent writes";
        const Version = struct { v: u32 };
        const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
        const version = std.json.parseFromSliceLeaky(Version, arena, text, options) catch
            return remote.unusable(diag, damaged);
        if (version.v == 0) return remote.unusable(diag, damaged);
        if (version.v > remembered_version) {
            return remote.unusable(diag, "it was written by a newer zcube-agent");
        }
        const File = struct { v: u32, server: ?[]const u8 = null, revision: u64, hash: []const u8 };
        const file = std.json.parseFromSliceLeaky(File, arena, text, .{}) catch
            return remote.unusable(diag, damaged);
        // Version 1 has no address and version 2 always has one.
        if ((file.server == null) != (file.v == 1)) return remote.unusable(diag, damaged);
        const hash = parse_hash(file.hash, diag) catch {
            diag.reset();
            return remote.unusable(diag, "its hash is not a chain hash");
        };
        if (file.server) |saved_for| {
            if (saved_for.len > remembered_server_bytes_max) {
                return remote.unusable(diag, damaged);
            }
            if (!std.mem.eql(u8, saved_for, server)) {
                // Another server's pair says nothing about this one: start fresh, and the
                // first save replaces the file.
                @memcpy(remote.previous_server[0..saved_for.len], saved_for);
                remote.previous_server_len = @intCast(saved_for.len);
                remote.notice = .server_changed;
                return;
            }
        }
        remote.known = .{ .revision = file.revision, .hash = hash };
        remote.saved = remote.known;
    }

    /// Writes the pair if the file is behind it and the last write is `verified_save_ms` old (the
    /// first one at once). Crash-safe through `put_atomic`. A failure leaves the file behind,
    /// which is safe, and the next call tries again.
    pub fn save(
        remote: *RemoteStore,
        state: agent_state.AgentState,
        now_ms: u64,
    ) agent_state.Error!void {
        return remote.save_pair(state, now_ms, true);
    }

    /// `save` without the wait between writes: at a clean stop, so the next start loses nothing.
    pub fn save_final(
        remote: *RemoteStore,
        state: agent_state.AgentState,
        now_ms: u64,
    ) agent_state.Error!void {
        return remote.save_pair(state, now_ms, false);
    }

    fn save_pair(
        remote: *RemoteStore,
        state: agent_state.AgentState,
        now_ms: u64,
        throttled: bool,
    ) agent_state.Error!void {
        const known = remote.known orelse return;
        if (remote.saved) |saved| {
            assert(saved.revision <= known.revision);
            if (saved.eql(known)) return;
            if (throttled and now_ms -| remote.saved_ms < constants.verified_save_ms) return;
        }
        const hex = std.fmt.bytesToHex(known.hash, .lower);
        const File = struct { v: u32, server: []const u8, revision: u64, hash: []const u8 };
        const file: File = .{
            .v = remembered_version,
            .server = remote.server,
            .revision = known.revision,
            .hash = &hex,
        };
        var buffer: [remembered_bytes_max]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        // The buffer holds the longest file: `load` bounds the address, the rest is fixed.
        std.json.Stringify.value(file, .{}, &writer) catch unreachable;
        writer.writeByte('\n') catch unreachable; // As above.
        try state.put_atomic(remembered_file, writer.buffered());
        remote.saved = known;
        remote.saved_ms = now_ms;
    }

    /// `<state dir>/remembered`, or the file's name alone if the directory is too long to name.
    pub fn remembered_path(remote: *const RemoteStore, buffer: []u8) []const u8 {
        const parts = .{ remote.state_dir, remembered_file };
        return std.fmt.bufPrint(buffer, "{s}/{s}", parts) catch remembered_file;
    }

    fn unusable(remote: *const RemoteStore, diag: *Diag, reason: []const u8) error{BackendFailed} {
        var buffer: [constants.state_path_bytes_max + 16]u8 = undefined;
        const where = remote.remembered_path(&buffer);
        return failures.remembered_unusable(diag, where, "read", reason);
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

/// A chain hash as the server writes it: 64 lower-case hex digits.
fn parse_hash(text: []const u8, diag: *Diag) store.Error!store.Hash {
    var hash: store.Hash = undefined;
    if (text.len != store.hash_bytes * 2) return bad(diag, "the reply's chain hash is not a hash");
    const decoded = std.fmt.hexToBytes(&hash, text) catch
        return bad(diag, "the reply's chain hash is not a hash");
    assert(decoded.len == store.hash_bytes);
    return hash;
}

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
fn refused(arena: Allocator, reply: Reply, diag: *Diag) store.Error {
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
    raise_bad_reply(diag, problem);
    return error.BackendFailed;
}

fn unsupported(diag: *Diag, what: []const u8) store.Error {
    assert(diag.code == null);
    diag.raise(.B0001);
    diag.cause("the agent asked its store for {s}, which it does not offer", .{what});
    return error.BackendFailed;
}
