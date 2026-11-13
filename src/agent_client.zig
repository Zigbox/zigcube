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
const Clock = @import("clock.zig").Clock;
const fencing = @import("fencing.zig");
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
    /// A cap on the I/O timeout, for a caller that must not wait past a deadline of its own (the
    /// agent's fence). Null leaves the transport's timeout. A transport ends the whole call,
    /// connecting included, within `hold_ms` plus this.
    timeout_ms: ?u32 = null,
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
    /// The agent's monotonic clock and the time before which every exchange must end (the
    /// fence): a request's I/O timeout is capped by what is left. No clock, no cap.
    mono: ?Clock = null,
    deadline_ms: u64 = std.math.maxInt(u64),
    /// Run before every exchange, if set (`Deadline.hook_fn`): it may move `deadline_ms`.
    before_context: ?*anyopaque = null,
    before_fn: ?*const fn (context: *anyopaque) void = null,
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
    /// The cluster CA's key id the last answer carried (null: none did, or no CA).
    ca_key_id: ?[8]u8 = null,
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

    /// Caps every later exchange so that it ends by `deadline_ms` on `mono`.
    pub fn set_deadline(remote: *RemoteStore, mono: Clock, deadline_ms: u64) void {
        remote.mono = mono;
        remote.deadline_ms = deadline_ms;
    }

    /// The agent's `Context.deadline` for this store: the agent moves the cap within a step,
    /// on the clock given to `set_deadline` first.
    pub fn deadline_fn(context: *anyopaque, deadline_ms: u64) void {
        const remote = from(context);
        assert(remote.mono != null);
        remote.deadline_ms = deadline_ms;
    }

    /// The agent's `Deadline.hook_fn` for this store.
    pub fn hook_fn(
        context: *anyopaque,
        hook_context: ?*anyopaque,
        hook: ?*const fn (hook_context: *anyopaque) void,
    ) void {
        const remote = from(context);
        remote.before_context = hook_context;
        remote.before_fn = hook;
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
        if (fencing.inequality_problem(answer.lease.ttl_ms)) |problem| {
            fencing.raise_problem(diag, answer.lease.ttl_ms, problem);
            return error.BackendFailed;
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
        // Only `job-observed` is paged (by run name); every other reply is whole: agent_api.zig.
        const paged_prefix = records.job_observed_prefix(remote.node);
        const paged = std.mem.eql(u8, options.prefix, paged_prefix.slice());
        if (options.continue_after != null) assert(paged);
        assert(!options.reverse);
        const observed = records.observed_prefix(remote.node);
        const assigned = records.assigned_prefix(remote.node);
        const job_observed = records.job_observed_prefix(remote.node);
        const Mapped = struct { prefix: []const u8, suffix: []const u8 };
        const mapped = [_]Mapped{
            .{ .prefix = records.prefix_replicas, .suffix = "/replicas" },
            .{ .prefix = observed.slice(), .suffix = "/observed" },
            .{ .prefix = assigned.slice(), .suffix = "/assigned" },
            .{ .prefix = records.prefix_job_runs, .suffix = "/runs" },
            .{ .prefix = job_observed.slice(), .suffix = "/job-observed" },
        };
        const suffix: []const u8 = for (mapped) |entry| {
            if (std.mem.eql(u8, options.prefix, entry.prefix)) break entry.suffix;
        } else return unsupported(diag, "a list of anything but the node's records");
        var target = try remote.path(arena, suffix, diag);
        if (options.continue_after) |key| {
            assert(std.mem.startsWith(u8, key, options.prefix));
            const at = options.at_revision orelse
                return unsupported(diag, "a page without its revision");
            target = std.fmt.allocPrint(arena, "{s}?after={s}&at={d}", .{
                target,
                key[options.prefix.len..],
                at,
            }) catch return failures.no_memory(diag);
        }
        const reply = try remote.exchange(arena, .{ .method = "GET", .target = target }, diag);
        if (reply.status != 200) return refused(arena, reply, diag);
        const result = try list_result(arena, reply.body, options.limit, paged, diag);
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
        paged: bool,
        diag: *Diag,
    ) store.Error!store.ListResult {
        const Answer = struct { revision: u64, kvs: []const KvJson, more: bool = false };
        const answer = try parse(Answer, arena, body, diag);
        if (answer.more and answer.kvs.len == 0) {
            return bad(diag, "the server paged an empty reply");
        }
        if (answer.more and !paged) return bad(diag, "the server paged a reply that is whole");
        // A paged reply holds a fixed page: a caller that asked for less is given the first of
        // it, and resumes after the last one it got.
        const kept = if (paged) @min(answer.kvs.len, limit) else answer.kvs.len;
        const cut = kept < answer.kvs.len;
        if (!paged and answer.kvs.len > limit) {
            return bad(diag, "the server listed more records than were asked for");
        }
        const kvs = arena.alloc(store.KeyValue, kept) catch return failures.no_memory(diag);
        for (answer.kvs[0..kept], kvs) |item, *slot| {
            const invalid = "the server listed a record that is not valid";
            if (store.key_problem(item.key) != null) return bad(diag, invalid);
            if (item.mod_revision > answer.revision) return bad(diag, invalid);
            // Revisions start at 1: a record at 0 would be an assignment epoch of 0, which the
            // agent never reports under.
            if (item.mod_revision == 0) return bad(diag, invalid);
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
        const resume_after: ?[]const u8 = if (cut or answer.more) kvs[kvs.len - 1].key else null;
        return .{ .kvs = kvs, .revision = answer.revision, .continue_after = resume_after };
    }

    // ---- Transactions ----

    fn txn_impl(
        context: *anyopaque,
        request: store.TxnRequest,
        diag: *Diag,
    ) store.Error!store.TxnResult {
        const remote = from(context);
        if (request.on_success.len == 1 and is_job_report(remote, request.on_success[0])) {
            return remote.job_txn(request, diag);
        }
        const tenure = try remote.tenure_of(request.compares, diag);
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
        const registering = std.mem.eql(u8, first, node_key.slice());
        if (registering and tenure != 0) return unsupported(diag, "a registration with a compare");
        const summary_key = records.node_store_key(remote.node);
        const publishing = std.mem.eql(u8, first, summary_key.slice());
        const pulling = std.mem.startsWith(u8, first, records.prefix_pulls);
        const sent: Request = if (registering)
            try remote.registration(arena, request.on_success, diag)
        else if (publishing)
            try remote.summary(arena, request.on_success, tenure, diag)
        else if (pulling)
            try remote.pull(arena, request.on_success, tenure, diag)
        else
            try remote.report(arena, request.on_success, tenure, diag);
        const reply = try remote.exchange(arena, sent, diag);
        if (reply.status != 200) {
            // The tenure ended (I2): a transaction whose compare failed, as in any store.
            if (refusal_code(arena, reply.body)) |text| {
                if (std.mem.eql(u8, text, "ZC-E0510")) {
                    // A registration that names a tenure the node has moved past is refused, not
                    // a compare that failed: the agent has no tenure of its own to fence yet.
                    if (registering) return tenure_ended(remote, diag);
                    return .{ .succeeded = false, .revision = 0 };
                }
            }
            return refused(arena, reply, diag);
        }
        const Answer = struct { revision: u64 };
        const answer = try parse(Answer, arena, reply.body, diag);
        return .{ .succeeded = true, .revision = answer.revision };
    }

    fn is_job_report(remote: *const RemoteStore, op: store.Op) bool {
        const prefix = records.job_observed_prefix(remote.node);
        return std.mem.startsWith(u8, store.op_key(op), prefix.slice());
    }

    /// `POST /v1/agent/nodes/{node}/job-observed`: one put of `/job-observed/<node>/<name>`. Its
    /// compares are the tenure and, for a claim, the run's revision; the server derives the rest
    /// (the assignment and the absent observation) from the record.
    fn job_txn(
        remote: *RemoteStore,
        request: store.TxnRequest,
        diag: *Diag,
    ) store.Error!store.TxnResult {
        if (request.on_failure.len > 0) return unsupported(diag, "a report with a failure branch");
        var arena_state = std.heap.ArenaAllocator.init(remote.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const put = switch (request.on_success[0]) {
            .put => |value| value,
            .delete => return unsupported(diag, "the delete of a job observation"),
        };
        var tenure: u64 = 0;
        var run_revision: u64 = 0;
        var observed_revision: u64 = 0;
        const node_key = records.node_key(remote.node);
        for (request.compares) |cmp| {
            if (std.mem.eql(u8, cmp.key, node_key.slice())) {
                tenure = cmp.mod_revision;
            } else if (std.mem.startsWith(u8, cmp.key, records.prefix_job_runs)) {
                run_revision = cmp.mod_revision;
            } else if (std.mem.startsWith(u8, cmp.key, records.prefix_job_observed)) {
                observed_revision = cmp.mod_revision;
            } else if (!std.mem.startsWith(
                u8,
                cmp.key,
                records.assigned_prefix(remote.node).slice(),
            )) {
                return unsupported(diag, "a report with a compare the server cannot carry");
            }
        }
        if (tenure == 0) return unsupported(diag, "a job report without a tenure");
        var out: std.Io.Writer.Allocating = .init(arena);
        var json: std.json.Stringify = .{ .writer = &out.writer };
        json.beginObject() catch return failures.no_memory(diag);
        json.objectField("tenure") catch return failures.no_memory(diag);
        json.write(tenure) catch return failures.no_memory(diag);
        json.objectField("run_revision") catch return failures.no_memory(diag);
        json.write(run_revision) catch return failures.no_memory(diag);
        if (observed_revision != 0) { // Additive: absent unless a claim replaces a leftover.
            json.objectField("observed_revision") catch return failures.no_memory(diag);
            json.write(observed_revision) catch return failures.no_memory(diag);
        }
        json.objectField("value") catch return failures.no_memory(diag);
        json.beginWriteRaw() catch return failures.no_memory(diag);
        json.writer.writeAll(put.value) catch return failures.no_memory(diag);
        json.endWriteRaw();
        json.endObject() catch return failures.no_memory(diag);
        const body = out.toOwnedSlice() catch return failures.no_memory(diag);
        const target = try remote.path(arena, "/job-observed", diag);
        const request_http: Request = .{ .method = "POST", .target = target, .body = body };
        const reply = try remote.exchange(arena, request_http, diag);
        if (reply.status != 200) {
            // A report that was not applied (`applied: false`) is a result. A tenure that ended
            // is not: it comes back as ZC-E0510, which the agent fences on at once.
            if (refusal_code(arena, reply.body)) |text| {
                if (std.mem.eql(u8, text, "ZC-E0510")) return tenure_ended(remote, diag);
            }
            return refused(arena, reply, diag);
        }
        const Answer = struct { revision: u64, applied: bool = true };
        const answer = try parse(Answer, arena, reply.body, diag);
        return .{ .succeeded = answer.applied, .revision = answer.revision };
    }

    /// The tenure a transaction's one compare names: a compare on this node's `/nodes/<node>`
    /// key, the only one the agent endpoints can carry. 0 for no compare.
    fn tenure_of(
        remote: *RemoteStore,
        compares: []const store.Compare,
        diag: *Diag,
    ) store.Error!u64 {
        if (compares.len == 0) return 0;
        const node_key = records.node_key(remote.node);
        const fits = compares.len == 1 and compares[0].mod_revision > 0 and
            std.mem.eql(u8, compares[0].key, node_key.slice());
        if (!fits) return unsupported(diag, "a transaction with compares other than the tenure");
        return compares[0].mod_revision;
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
            .replaces = node.replaces,
        }, diag);
        const target = try remote.path(arena, "", diag);
        return .{ .method = "PUT", .target = target, .body = body };
    }

    /// `PUT /v1/agent/nodes/{node}/store`: the one put of `/node-store/<node>` on the node's
    /// lease, under the tenure.
    fn summary(
        remote: *RemoteStore,
        arena: Allocator,
        ops: []const store.Op,
        tenure: u64,
        diag: *Diag,
    ) store.Error!Request {
        if (tenure == 0) return unsupported(diag, "a summary without a tenure");
        if (ops.len != 1) return unsupported(diag, "a summary with other operations");
        const put = switch (ops[0]) {
            .put => |value| value,
            .delete => return unsupported(diag, "the delete of the node's summary"),
        };
        if (put.lease == store.lease_none) return unsupported(diag, "a summary with no lease");
        var out: std.Io.Writer.Allocating = .init(arena);
        var json: std.json.Stringify = .{ .writer = &out.writer };
        json.beginObject() catch return failures.no_memory(diag);
        json.objectField("tenure") catch return failures.no_memory(diag);
        json.write(tenure) catch return failures.no_memory(diag);
        json.objectField("lease") catch return failures.no_memory(diag);
        json.write(put.lease) catch return failures.no_memory(diag);
        json.objectField("summary") catch return failures.no_memory(diag);
        json.beginWriteRaw() catch return failures.no_memory(diag);
        json.writer.writeAll(put.value) catch return failures.no_memory(diag);
        json.endWriteRaw();
        json.endObject() catch return failures.no_memory(diag);
        const body = out.toOwnedSlice() catch return failures.no_memory(diag);
        const target = try remote.path(arena, "/store", diag);
        return .{ .method = "PUT", .target = target, .body = body };
    }

    /// `POST /v1/agent/nodes/{node}/pulls`: the one put of a `/pulls/<node>/<tree>` record,
    /// under the tenure. The server builds the key from the record, so the key is checked here.
    fn pull(
        remote: *RemoteStore,
        arena: Allocator,
        ops: []const store.Op,
        tenure: u64,
        diag: *Diag,
    ) store.Error!Request {
        if (tenure == 0) return unsupported(diag, "a pull record without a tenure");
        if (ops.len != 1) return unsupported(diag, "a pull record with other operations");
        const put = switch (ops[0]) {
            .put => |value| value,
            .delete => return unsupported(diag, "the delete of a pull record"),
        };
        const record = std.json.parseFromSliceLeaky(records.Pull, arena, put.value, .{
            .ignore_unknown_fields = true,
        }) catch return unsupported(diag, "a pull record that is not a pull record");
        const wanted = records.pull_key(remote.node, record.tree);
        if (!std.mem.eql(u8, put.key, wanted.slice())) {
            return unsupported(diag, "a pull record under a key that is not its own");
        }
        var out: std.Io.Writer.Allocating = .init(arena);
        var json: std.json.Stringify = .{ .writer = &out.writer };
        json.beginObject() catch return failures.no_memory(diag);
        json.objectField("tenure") catch return failures.no_memory(diag);
        json.write(tenure) catch return failures.no_memory(diag);
        json.objectField("pull") catch return failures.no_memory(diag);
        json.beginWriteRaw() catch return failures.no_memory(diag);
        json.writer.writeAll(put.value) catch return failures.no_memory(diag);
        json.endWriteRaw();
        json.endObject() catch return failures.no_memory(diag);
        const body = out.toOwnedSlice() catch return failures.no_memory(diag);
        const target = try remote.path(arena, "/pulls", diag);
        return .{ .method = "POST", .target = target, .body = body };
    }

    /// `POST /v1/agent/nodes/{node}/observed`: puts and deletes of the node's observed records.
    fn report(
        remote: *RemoteStore,
        arena: Allocator,
        ops: []const store.Op,
        tenure: u64,
        diag: *Diag,
    ) store.Error!Request {
        if (tenure == 0) return unsupported(diag, "an observed write without a tenure");
        const prefix = records.observed_prefix(remote.node);
        var out: std.Io.Writer.Allocating = .init(arena);
        var json: std.json.Stringify = .{ .writer = &out.writer };
        json.beginObject() catch return failures.no_memory(diag);
        json.objectField("tenure") catch return failures.no_memory(diag);
        json.write(tenure) catch return failures.no_memory(diag);
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
        const remote = from(context);
        // The one read the agent makes of a single key: the input of a run it has claimed.
        const prefix = records.prefix_job_input;
        if (at_revision != null or !std.mem.startsWith(u8, key, prefix)) {
            return unsupported(diag, "get of anything but a run's input");
        }
        const name = key[prefix.len..];
        if (records.name_problem(name, constants.service_name_bytes_max) != null) {
            return unsupported(diag, "get of a run's input under a bad name");
        }
        const suffix = std.fmt.allocPrint(arena, "/runs/{s}/input", .{name}) catch
            return failures.no_memory(diag);
        const target = try remote.path(arena, suffix, diag);
        const reply = try remote.exchange(arena, .{ .method = "GET", .target = target }, diag);
        if (reply.status != 200) {
            // The server's own answer that the run has no input it can give: not a fault of
            // the link (ZC-E0523), so the agent can tell it from one.
            const code = refusal_code(arena, reply.body) orelse "";
            if (std.mem.endsWith(u8, code, "E0523")) {
                if (!refusal_says(arena, reply.body, records.input_mismatch_phrase)) {
                    return .{ .kv = null, .revision = 1 };
                }
                // A damaged input is not an absent one: hand over a value that does not
                // decode, which the agent reads as a mismatch. The phrase above is wire
                // protocol (see `records.input_mismatch_phrase`). The "null" stands for
                // "damaged" through the `Store` interface: `records.read(JobInput)` must
                // keep refusing it.
                const damaged: store.KeyValue = .{
                    .key = key,
                    .value = "null",
                    .create_revision = 1,
                    .mod_revision = 1,
                    .lease = store.lease_none,
                };
                return .{ .kv = damaged, .revision = 1 };
            }
            return refused(arena, reply, diag);
        }
        const Answer = struct { input: Json };
        const answer = try parse(Answer, arena, reply.body, diag);
        const value = std.json.Stringify.valueAlloc(arena, answer.input, .{}) catch
            return failures.no_memory(diag);
        // The agent reads the value and nothing else of the record.
        const kv: store.KeyValue = .{
            .key = key,
            .value = value,
            .create_revision = 1,
            .mod_revision = 1,
            .lease = store.lease_none,
        };
        return .{ .kv = kv, .revision = 1 };
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
        if (remote.before_fn) |before| before(remote.before_context.?);
        if (remote.mono) |clock| {
            // The hold and the I/O after it together end by the deadline; a hold takes at most
            // half of what is left, so that a reply has time to come.
            const left = remote.deadline_ms -| clock.now_ms();
            if (left == 0) return fence_due(diag);
            if (left < std.math.maxInt(u32)) {
                const hold: u32 = @intCast(@min(request.hold_ms, left / 2));
                sent.hold_ms = hold;
                sent.timeout_ms = @intCast(@max(1, @min(left - hold, io_cap(request))));
            }
        }
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
            ca_key_id: ?[]const u8 = null,
        };
        const Answer = struct { chain: ?ChainJson = null };
        const answer = try parse(Answer, arena, body, diag);
        const chain = answer.chain orelse
            return bad(diag, "the reply carries no chain pair: the server is older than the agent");
        const now: Pair = .{ .revision = chain.revision, .hash = try parse_hash(chain.hash, diag) };
        remote.ca_key_id = null;
        if (chain.ca_key_id) |text| {
            var id: [8]u8 = undefined;
            const decoded = std.fmt.hexToBytes(&id, text) catch &[0]u8{};
            if (decoded.len != id.len) {
                return bad(diag, "the reply's CA key id is not 16 hex digits");
            }
            remote.ca_key_id = id;
        }
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
pub fn refusal_code(arena: Allocator, body: []const u8) ?[]const u8 {
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    const parsed = std.json.parseFromSliceLeaky(Refusal, arena, body, options) catch return null;
    if (parsed.diagnostics.len == 0) return null;
    return parsed.diagnostics[0].code;
}

/// Whether any cause of the server's first diagnostic contains `phrase`.
fn refusal_says(arena: Allocator, body: []const u8, phrase: []const u8) bool {
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    const parsed = std.json.parseFromSliceLeaky(Refusal, arena, body, options) catch return false;
    if (parsed.diagnostics.len == 0) return false;
    for (parsed.diagnostics[0].causes) |text| {
        if (std.mem.indexOf(u8, text, phrase) != null) return true;
    }
    return false;
}

/// ZC-E0504 carrying the server's own diagnostic: its code and summary, and its innermost cause.
pub fn refused(arena: Allocator, reply: Reply, diag: *Diag) store.Error {
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

/// ZC-E0510: the server says this agent's tenure on its node has ended.
fn tenure_ended(remote: *const RemoteStore, diag: *Diag) store.Error {
    assert(diag.code == null);
    diag.raise(.E0510);
    diag.cause("zcube-server says node {s} is not registered under this agent's tenure", .{
        remote.node,
    });
    diag.fix(.{ .sentence = "the agent stops its containers and registers the node again" });
    return error.BackendFailed;
}

/// ZC-E0504 for a reply that cannot be right.
fn io_cap(request: Request) u64 {
    return request.timeout_ms orelse constants.agent_io_timeout_ms;
}

/// The deadline of a call has passed before it was made: nothing is sent. The deadline is the
/// fence's, or a run's deadline or kill, which the agent acts on before it calls again.
fn fence_due(diag: *Diag) store.Error {
    assert(diag.code == null);
    diag.raise(.E0503);
    diag.cause(
        "the agent did not call zcube-server: its lease's fence, or a run's deadline, has come",
        .{},
    );
    diag.fix(.{
        .sentence = "make zcube-server reachable from the node; the agent fences meanwhile",
    });
    return error.BackendFailed;
}

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
