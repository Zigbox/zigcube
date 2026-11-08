//! The read-only API of docs/api.md as a function from bytes to bytes: a request (method, path,
//! query, the client's request id) in; a status, a request id and a JSON body out. The HTTP
//! server is a loop that reads a request, calls `handle` and writes the reply; the browser demo
//! calls it directly. Nothing here opens a socket, waits or reads a clock but the injected one.
//!
//! Endpoints: `GET /v1/status`, `/v1/list`, `/v1/watch`, `/v1/leases`, `/v1/why/{kind}/{name}`,
//! `/v1/codes`, `/v1/explain/{code}`. A failure is a DIAGNOSTICS.md diagnostic in
//! `{"request_id", "diagnostics": [...]}`, with the HTTP status the blame decides.
//!
//! **Watch is a long poll, and the wait is the shell's.** The handler answers what is ready now,
//! with a bookmark (`revision`): events with `mod_revision >= from`, and an idle answer still
//! advances the bookmark. If the client asked to wait (`timeout`, default and maximum 25000 ms)
//! and nothing is ready, `Response.hold_ms` says how long the shell may hold the reply, and
//! `hold_prefixes` which keys' changes end the hold; the shell then calls `handle` again with the
//! same request. A handler that waited would hang a browser.
//!
//! **Writes** (proposed in docs/api.md, owner approval pending): `POST /v1/apply` takes a service
//! as JSON (`?dry_run=1` answers what would change and writes nothing), `DELETE
//! /v1/services/{name}` deletes one. Both are `apply.zig`'s functions behind a route, and both
//! are unauthenticated until the API has auth.
//!
//! **Jobs** (B1; docs/api.md): `POST /v1/jobs`, `GET /v1/jobs`, `GET /v1/jobs/{name}`, `POST
//! /v1/jobs/{name}/cancel` and `GET /v1/why/job/{name}` are `job_api.zig`'s functions behind
//! routes. `POST /v1/jobs` is the one body over `api_request_bytes_max`: it may be
//! `job_request_bytes_max`.
//!
//! **Secrets.** `env` values in `/services/` and `/replicas/` records are never sent to a
//! read-only token: the names stay and each value is `null` (docs/api.md item 8; the replica
//! carries a copy, docs/keys.md).

const std = @import("std");
const assert = std.debug.assert;
const zigbox = @import("zigbox");
const codes = @import("diag/codes.zig");
const agent_api = @import("agent_api.zig");
const apply_mod = @import("apply.zig");
const job_api = @import("job_api.zig");
const constants = @import("constants.zig");
const accounting = @import("allocations.zig");
const controller = @import("controller.zig");
const diag_mod = @import("diag.zig");
const peer_ca = @import("peer_ca.zig");
const records = @import("records.zig");
const runtime_codes = @import("runtime_codes.zig");
const store = @import("store.zig");
const failures = @import("store_failures.zig");
const store_verified = @import("store_verified.zig");
const text_util = @import("text.zig");
const why_mod = @import("why.zig");

const Allocator = std.mem.Allocator;
const Context = controller.Context;
const Diag = diag_mod.Diag;
const Diagnostic = diag_mod.Diagnostic;

pub const Request = struct {
    method: []const u8,
    /// Without the query: "/v1/list".
    path: []const u8,
    /// The raw query string without the '?': "prefix=%2Fservices%2F&limit=10".
    query: []const u8 = "",
    /// The client's `X-Request-Id` header, if it sent one.
    request_id: ?[]const u8 = null,
    /// The request body, for `POST /v1/apply` and `POST /v1/jobs`. The shell reads at most
    /// `http_body_bytes_max` of it, and `job_request_bytes_max` for `POST /v1/jobs`.
    body: []const u8 = "",
    /// False asks a watch not to say "hold me": the shell sets it when it asks again after a hold
    /// ended, so the same request is answered with what is ready and nothing more.
    hold: bool = true,
};

pub const Response = struct {
    /// 200 unless a route says otherwise (201 created, 202 accepted).
    status: u16,
    /// For the `X-Request-Id` header, on success and failure.
    request_id: []const u8,
    /// The `Content-Type` is always `application/json`.
    body: []const u8,
    /// The shell may hold this reply this long for a change under `hold_prefixes` (watch only).
    hold_ms: u32 = 0,
    hold_prefixes: []const []const u8 = &.{},
};

/// What the server tells about itself, and the counter that assigns request ids.
pub const Api = struct {
    version: []const u8,
    /// "postgres", "sqlite" or "memory": named in `/v1/status`.
    backend: []const u8,
    started_at_ms: u64,
    /// False for a token that may write: it sees `env` values.
    read_only: bool = true,
    /// Atomic so that several reads can run at once; the writes (`POST`, `DELETE`) also change
    /// `source`, and the shell runs those one at a time.
    counter: std.atomic.Value(u32) = .init(0),
    /// Names this start of the server in the ids it issues (`r-<instance>-<counter>`), so that two
    /// starts, or two servers, never issue the same id. The shell supplies it (it may read the
    /// clock; the core may not). 0 means "none": ids are then `r-<counter>`, as in the simulation.
    instance: u32 = 0,
    /// The ttl of the leases the agent endpoints grant. `server_config.zig` refuses a value an
    /// agent cannot fence in time for (ZC-E0121).
    lease_ttl_ms: u32 = constants.lease_ttl_ms,
    /// Names the decisions the write endpoints record. Its instance number is the shell's.
    source: controller.DecisionSource = .{ .instance = 0 },
    /// The server's guard against a store that went backwards, for
    /// `POST /v1/store/accept-rollback`.
    /// Null in the simulation, which has no guard.
    verified: ?*store_verified.VerifiedStore = null,
    /// False when the server keeps no pair for its store across its own restarts (a memory
    /// store, which starts empty every time): the agent's answers then say `"verified": false`
    /// and the agent keeps no pair either (`agent_api.zig`). True in the simulation and tests.
    pair_kept: bool = true,
    /// The cluster CA (docs/peer.md), for `POST /v1/agent/nodes/{node}/credential`. Null in the
    /// simulation, which has no peers: the endpoint then answers 404.
    ca: ?*const peer_ca.Ca = null,

    /// Answers one request. `ctx.arena` holds the answer: it stays valid until the arena is reset.
    pub fn handle(api: *Api, ctx: *const Context, request: Request) Response {
        assert(ctx.diag.code == null);
        const id = api.assign_id(ctx, request);
        if (api.route(ctx, request, id)) |reply| {
            return .{
                .status = reply.status,
                .request_id = id,
                .body = reply.body,
                .hold_ms = reply.hold_ms,
                .hold_prefixes = reply.hold_prefixes,
            };
        } else |_| {
            return error_response(ctx, id);
        }
    }

    /// The client's id if it sent a valid one, else a new one (an invalid one is refused by
    /// `route`, and the refusal is reported under the new id).
    pub fn assign_id(api: *Api, ctx: *const Context, request: Request) []const u8 {
        if (request.request_id) |sent| {
            if (id_problem(sent) == null) return sent;
        }
        const number = api.counter.fetchAdd(1, .monotonic) +% 1;
        if (api.instance == 0) {
            return std.fmt.allocPrint(ctx.arena, "r-{x:0>7}", .{number}) catch "r-0000000";
        }
        const format = "r-{x:0>8}-{x:0>7}";
        return std.fmt.allocPrint(ctx.arena, format, .{ api.instance, number }) catch "r-00000000";
    }

    fn route(api: *Api, ctx: *const Context, request: Request, id: []const u8) Failure!Reply {
        if (request.request_id) |sent| {
            if (id_problem(sent)) |problem| return bad_request(ctx, "X-Request-Id", problem);
        }
        const prefix = "/v1/";
        if (!std.mem.startsWith(u8, request.path, prefix)) return no_such(ctx, request.path);
        var parts = std.mem.splitScalar(u8, request.path[prefix.len..], '/');
        const first = parts.next().?; // A split always has a first part.
        if (std.mem.eql(u8, first, "agent")) {
            // The agent's endpoints (agent_api.zig) parse their own few parameters.
            const agent = try agent_api.route(
                ctx,
                request.method,
                &parts,
                request.query,
                request.body,
                request.hold,
                api.lease_ttl_ms,
                api.pair_kept,
                api.ca,
            );
            return .{
                .body = agent.body,
                .hold_ms = agent.hold_ms,
                .hold_prefixes = agent.hold_prefixes,
            };
        }
        const query = try Query.parse(ctx, request.query);
        const call: Call = .{
            .api = api,
            .ctx = ctx,
            .query = &query,
            .parts = &parts,
            .hold = request.hold,
        };
        if (std.mem.eql(u8, request.method, "POST")) {
            return call.write_post(first, request.body, id);
        }
        if (std.mem.eql(u8, request.method, "DELETE")) return call.write_delete(first, id);
        if (!std.mem.eql(u8, request.method, "GET")) {
            return bad_request(ctx, "method", "this API answers GET, POST and DELETE only");
        }
        if (std.mem.eql(u8, first, "status")) return call.status();
        if (std.mem.eql(u8, first, "list")) return call.list();
        if (std.mem.eql(u8, first, "jobs")) return call.jobs_get();
        if (std.mem.eql(u8, first, "watch")) return call.watch();
        if (std.mem.eql(u8, first, "leases")) return call.leases();
        if (std.mem.eql(u8, first, "why")) return call.why();
        if (std.mem.eql(u8, first, "codes")) return call.codes_list();
        if (std.mem.eql(u8, first, "check")) return call.check_allocations();
        if (std.mem.eql(u8, first, "explain")) return call.explain();
        if (std.mem.eql(u8, first, "stats")) return call.stats();
        return no_such(ctx, request.path);
    }
};

/// A reply that is not yet a `Response`: what a route returns.
const Reply = struct {
    status: u16 = 200,
    body: []const u8,
    hold_ms: u32 = 0,
    hold_prefixes: []const []const u8 = &.{},
};

/// The route failed and `ctx.diag` says why.
const Failure = error{Failed};

const Parts = std.mem.SplitIterator(u8, .scalar);

// ---- Writes ------------------------------------------------------------------------------------

/// A conflicting write is read and planned again this many times before it is reported.
const apply_attempts_max: u32 = 3;
const pulls_limit_default: u64 = 50;
/// Who a write is attributed to while the API has no auth.
const anonymous = "anonymous";
const applied_by_bytes_max: u32 = 64;

/// The body of `POST /v1/apply`: the fields of a service the user writes (docs/keys.md), as JSON.
const ApplyBody = struct {
    name: []const u8,
    image: []const u8,
    replicas: u32,
    command: []const []const u8,
    env: []const records.Pair = &.{},
    limits: records.Limits = .{},
    source: []const u8 = "",
    applied_by: []const u8 = anonymous,
};

const CheckFinding = struct { decision: []const u8, revision: u64 };

/// One node in `GET /v1/check/allocations`; `recorded` is null when there is no record.
const CheckNode = struct {
    node: []const u8,
    recorded: ?records.Tally,
    reconstructed: records.Tally,
    consistent: bool,
    finding: ?CheckFinding,
};

const RepairReply = struct {
    request_id: []const u8,
    node: []const u8,
    action: []const u8,
    recorded: records.Tally,
    reconstructed: records.Tally,
    revision: store.Revision,
    decision: []const u8,
};

const NodeTally = accounting.NodeTally;

fn open_finding(nodes: []const NodeTally, node: []const u8) ?*const NodeTally {
    for (nodes) |*tally| {
        if (!std.mem.eql(u8, tally.node, node)) continue;
        if (tally.finding == null) return null;
        return tally;
    }
    return null;
}

fn no_finding(ctx: *const Context, node: []const u8) Failure {
    assert(ctx.diag.code == null);
    ctx.diag.raise(.E0402);
    ctx.diag.cause("the allocation auditor has no open finding on node {s}", .{node});
    ctx.diag.fix(.{
        .sentence = "see every node's accounting",
        .command = "zcube check allocations",
    });
    return error.Failed;
}

fn unconfirmed(ctx: *const Context, tally: *const accounting.NodeTally) Failure {
    assert(ctx.diag.code == null);
    const recorded = tally.recorded orelse accounting.zero;
    const now = tally.reconstructed;
    ctx.diag.raise(.E0401);
    ctx.diag.cause(
        "would write {d} assignments, {d} cpu millis and {d} memory bytes to /allocations/{s}, " ++
            "which records {d}, {d} and {d}",
        .{
            now.count,                       now.allocated.cpu_millis,
            now.allocated.memory_bytes,      tally.node,
            recorded.count,                  recorded.allocated.cpu_millis,
            recorded.allocated.memory_bytes,
        },
    );
    ctx.diag.fix_with(
        "if that is right, confirm it",
        "zcube repair allocations {s} --confirm",
        .{tally.node},
    );
    return error.Failed;
}

/// One open finding in `GET /v1/status`.
const Finding = struct {
    node: []const u8,
    recorded: records.Tally,
    reconstructed: records.Tally,
    revision: u64,
    decision: []const u8,
};

const WriteReply = struct {
    request_id: []const u8,
    dry_run: bool,
    action: []const u8,
    name: []const u8,
    generation: ?u64 = null,
    change: []const u8,
    revision: ?store.Revision = null,
    decision: ?[]const u8 = null,
};

fn pair_json(ctx: *const Context, out: *Out, pair: ?store_verified.Pair) Failure!void {
    try out.begin_object();
    if (pair) |known| {
        try out.member("revision", known.revision);
        const hex = std.fmt.allocPrint(ctx.arena, "{x}", .{&known.hash}) catch
            return no_memory(ctx);
        try out.member("hash", hex);
    }
    try out.end_object();
}

fn apply_input(ctx: *const Context, body: []const u8, id: []const u8) Failure!apply_mod.Input {
    if (body.len == 0) return bad_request(ctx, "body", "is required: the service as JSON");
    if (body.len > constants.api_request_bytes_max) {
        return bad_request(ctx, "body", "is larger than 65536 bytes");
    }
    const parsed = std.json.parseFromSliceLeaky(ApplyBody, ctx.arena, body, .{}) catch |err| {
        if (err == error.OutOfMemory) return no_memory(ctx);
        const problem = "is not a service: it needs name, image, replicas and command";
        return bad_request(ctx, "body", problem);
    };
    try check_applied_by(ctx, parsed.applied_by);
    return .{
        .name = parsed.name,
        .image = parsed.image,
        .replicas = parsed.replicas,
        .command = parsed.command,
        .env = parsed.env,
        .limits = parsed.limits,
        .source = parsed.source,
        .applied_by = parsed.applied_by,
        .request_id = id,
    };
}

/// `applied_by` goes into a decision's reason, which people read: a short printable name.
fn check_applied_by(ctx: *const Context, text: []const u8) Failure!void {
    if (text.len == 0 or text.len > applied_by_bytes_max) {
        return bad_request(ctx, "applied_by", "must be 1 to 64 bytes");
    }
    for (text) |byte| {
        if (!text_util.is_printable(byte)) {
            return bad_request(ctx, "applied_by", "may hold printable ASCII only");
        }
    }
}

/// A JSON value that is skipped, not built: only its presence is kept. A `std.json.Value` of a
/// 409,600-byte array of zeros takes about 37 times that in the arena.
const Present = struct {
    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !Present {
        _ = allocator;
        _ = options;
        try source.skipValue();
        return .{};
    }
};

/// The body of `POST /v1/jobs`: a job as JSON. `relay` and `placement` are parsed so that they
/// can be refused by name (not built yet), not as unknown fields.
const JobBody = struct {
    name: []const u8,
    image: []const u8,
    source: []const u8 = "",
    command: []const []const u8,
    env: []const records.Pair = &.{},
    limits: records.JobLimits = .{},
    deadline_ms: u64,
    retries: u32 = 0,
    labels: []const records.Pair = &.{},
    grace_ms: u32 = 0,
    input: ?[]const u8 = null,
    input_env: ?[]const u8 = null,
    submit_by_ms: u64,
    relay: ?Present = null,
    placement: ?Present = null,
    applied_by: []const u8 = anonymous,
};

const CancelBody = struct { applied_by: []const u8 = anonymous };

/// A job's spec as `GET /v1/jobs/{name}` shows it: the names of its variables, never their
/// values (the input is not returned at all, only its digest and size).
const JobSpec = struct {
    name: []const u8,
    image: []const u8,
    source: []const u8,
    command: []const []const u8,
    env_names: []const []const u8,
    limits: records.JobLimits,
    deadline_ms: u64,
    retries: u32,
    labels: []const records.Pair,
    grace_ms: u32,
    input_env: ?[]const u8,
    input_digest: ?[]const u8,
    input_bytes: ?u64,
    submit_by_ms: u64,
    created_at_ms: u64,
    applied_by: []const u8,
    cancel_requested: ?records.JobCancel,

    fn of(ctx: *const Context, job: records.Job) Failure!JobSpec {
        return .{
            .name = job.name,
            .image = job.image,
            .source = job.source,
            .command = job.command,
            .env_names = try env_names(ctx, job.env),
            .limits = job.limits,
            .deadline_ms = job.deadline_ms,
            .retries = job.retries,
            .labels = job.labels,
            .grace_ms = job.grace_ms,
            .input_env = job.input_env,
            .input_digest = job.input_digest,
            .input_bytes = job.input_bytes,
            .submit_by_ms = job.submit_by_ms,
            .created_at_ms = job.created_at_ms,
            .applied_by = job.applied_by,
            .cancel_requested = job.cancel_requested,
        };
    }
};

fn env_names(ctx: *const Context, env: []const records.Pair) Failure![]const []const u8 {
    assert(env.len <= constants.runtime_env_count_max);
    const names = ctx.arena.alloc([]const u8, env.len) catch return no_memory(ctx);
    for (env, names) |pair, *name| name.* = pair[0];
    return names;
}

const JobReply = struct {
    request_id: []const u8,
    action: []const u8,
    name: []const u8,
    state: records.JobState,
    revision: ?store.Revision = null,
    decision: ?[]const u8 = null,
    end: ?records.JobEnd = null,
};

fn job_reply(ctx: *const Context, status: u16, reply: JobReply) Failure!Reply {
    const out = Out.create(ctx) catch return no_memory(ctx);
    out.json.options.emit_null_optional_fields = false;
    try out.value(reply);
    var done = try out.finish();
    done.status = status;
    return done;
}

fn job_conflict(ctx: *const Context, name: []const u8) Failure {
    assert(ctx.diag.code == null);
    ctx.diag.raise(.E0105);
    ctx.diag.cause("job {s} or the job counters changed during the request", .{name});
    ctx.diag.fix_with("look at it as it is now, then try again", "zcube job get {s}", .{name});
    return error.Failed;
}

fn job_input(ctx: *const Context, body: []const u8, id: []const u8) Failure!job_api.Input {
    if (body.len == 0) return bad_request(ctx, "body", "is required: the job as JSON");
    if (body.len > constants.job_request_bytes_max) {
        const problem = std.fmt.comptimePrint(
            "is larger than {d} bytes",
            .{constants.job_request_bytes_max},
        );
        return bad_request(ctx, "body", problem);
    }
    const parsed = std.json.parseFromSliceLeaky(JobBody, ctx.arena, body, .{}) catch |err| {
        if (err == error.OutOfMemory) return no_memory(ctx);
        return bad_request(ctx, "body", job_parse_problem(err));
    };
    try check_applied_by(ctx, parsed.applied_by);
    return .{
        .name = parsed.name,
        .image = parsed.image,
        .source = parsed.source,
        .command = parsed.command,
        .env = parsed.env,
        .limits = parsed.limits,
        .deadline_ms = parsed.deadline_ms,
        .retries = parsed.retries,
        .labels = parsed.labels,
        .grace_ms = parsed.grace_ms,
        .input = parsed.input,
        .input_env = parsed.input_env,
        .submit_by_ms = parsed.submit_by_ms,
        .relay = parsed.relay != null,
        .placement = parsed.placement != null,
        .applied_by = parsed.applied_by,
        .request_id = id,
    };
}

/// What was wrong with a job body, by the parser's own error: a missing field, an unknown one, a
/// value of the wrong type or a body that is not JSON each get a sentence of their own.
fn job_parse_problem(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingField => "is not a job: a required field is missing " ++
            "(name, image, command, deadline_ms, submit_by_ms)",
        error.UnknownField => "is not a job: it has a field the API does not know",
        error.DuplicateField => "is not a job: a field is given twice",
        error.UnexpectedToken,
        error.InvalidEnumTag,
        error.InvalidCharacter,
        error.Overflow,
        error.InvalidNumber,
        => "is not a job: a field has the wrong type, or a number is negative, " ++
            "fractional or too large for it",
        error.UnexpectedEndOfInput => "is not complete JSON: it ends too soon",
        else => "is not valid JSON",
    };
}

fn write_reply(ctx: *const Context, reply: WriteReply) Failure!Reply {
    const out = Out.create(ctx) catch return no_memory(ctx);
    out.json.options.emit_null_optional_fields = false;
    try out.value(reply);
    return out.finish();
}

fn conflict(ctx: *const Context, name: []const u8) Failure {
    assert(ctx.diag.code == null);
    ctx.diag.raise(.E0105);
    ctx.diag.cause("service {s} was changed by someone else during the request", .{name});
    const sentence = "look at it as it is now, then apply again";
    ctx.diag.fix_with(sentence, "zcube get service {s}", .{name});
    return error.Failed;
}

/// A reply for a request the shell refuses before it reaches `handle` (too large, too many
/// connections): the failure already raised on `ctx.diag`, with the shell's own status.
pub fn refusal(ctx: *const Context, request_id: []const u8, status: u16) Response {
    var response = error_response(ctx, request_id);
    response.status = status;
    return response;
}

// ---- Request ids and errors --------------------------------------------------------------------

/// Null if `text` is a valid client request id: 8 to 64 of letters, digits and hyphens.
fn id_problem(text: []const u8) ?[]const u8 {
    if (text.len < constants.request_id_bytes_min) return "must be at least 8 bytes";
    if (text.len > constants.request_id_bytes_max) return "must be at most 64 bytes";
    for (text) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-') {
            return "may hold only letters, digits and hyphens";
        }
    }
    return null;
}

fn bad_request(ctx: *const Context, what: []const u8, problem: []const u8) Failure {
    assert(ctx.diag.code == null);
    ctx.diag.raise(.E0104);
    ctx.diag.cause("{s}: {s}", .{ what, problem });
    ctx.diag.fix(.{ .sentence = "see docs/api.md for the endpoint's parameters" });
    return error.Failed;
}

fn no_such(ctx: *const Context, path: []const u8) Failure {
    assert(ctx.diag.code == null);
    ctx.diag.raise(.E0101);
    ctx.diag.cause("the API serves nothing at {s}", .{path});
    ctx.diag.fix(.{
        .sentence = "the read-only API lives under /v1/",
        .command = "GET /v1/status",
    });
    return error.Failed;
}

fn no_memory(ctx: *const Context) Failure {
    if (ctx.diag.code == null) {
        ctx.diag.raise(.E0207);
        ctx.diag.cause("the memory set aside for this request ran out", .{});
        ctx.diag.fix(.{ .sentence = "ask for smaller pages" });
    }
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

/// Turns what the failing call left in `ctx.diag` into the error body and the status the blame
/// decides (docs/api.md, "Errors").
fn error_response(ctx: *const Context, request_id: []const u8) Response {
    const code = ctx.diag.code orelse {
        ctx.diag.raise(.B0001);
        ctx.diag.cause("a handler failed without saying why", .{});
        return error_response(ctx, request_id);
    };
    var diagnostic: Diagnostic = undefined;
    diag_mod.to_diagnostic(&diagnostic, ctx.diag);
    const body = error_body(ctx, request_id, &diagnostic) catch "{\"diagnostics\":[]}";
    return .{
        .status = status_for(code, diagnostic.blame),
        .request_id = request_id,
        .body = body,
    };
}

pub fn status_for(code: codes.Code, blame: zigbox.codes.Blame) u16 {
    switch (blame) {
        .user => {
            if (code == .E0101) return 404;
            if (code == .E0203) return 410;
            // The state the request rested on is not (or no longer) there.
            if (code == .E0105 or code == .E0402 or code == .E0403) return 409;
            if (code == .E0131) return 409;
            if (code == .E0132) return 429;
            if (code == .E0133) return 404;
            if (code == .E0134) return 410;
            return 400;
        },
        .environment => return 503,
        .external => {
            if (code == .E0201 or code == .E0213) return 503;
            return 502;
        },
        .internal => return 500,
    }
}

fn error_body(ctx: *const Context, request_id: []const u8, diagnostic: *Diagnostic) ![]const u8 {
    const out = try Out.create(ctx);
    out.begin_object() catch return error.OutOfMemory;
    out.field("request_id") catch return error.OutOfMemory;
    out.value(request_id) catch return error.OutOfMemory;
    out.field("diagnostics") catch return error.OutOfMemory;
    out.begin_array() catch return error.OutOfMemory;
    out.diagnostic(diagnostic) catch return error.OutOfMemory;
    out.end_array() catch return error.OutOfMemory;
    out.end_object() catch return error.OutOfMemory;
    return out.buffer.toOwnedSlice();
}

// ---- JSON output -------------------------------------------------------------------------------

/// A JSON writer into the request's arena that reports a full arena as `Failed`. It is created
/// in the arena so it does not move: the `Stringify` points at the buffer beside it.
const Out = struct {
    ctx: *const Context,
    buffer: std.Io.Writer.Allocating,
    json: std.json.Stringify,

    fn create(ctx: *const Context) error{OutOfMemory}!*Out {
        return create_sized(ctx, 0);
    }

    /// As `create`, with room for `bytes` of output taken at once: an arena frees nothing, so a
    /// buffer that grows leaves each smaller one behind. The output may still outgrow `bytes`.
    fn create_sized(ctx: *const Context, bytes: usize) error{OutOfMemory}!*Out {
        const out = try ctx.arena.create(Out);
        out.ctx = ctx;
        out.buffer = try .initCapacity(ctx.arena, bytes);
        out.json = .{ .writer = &out.buffer.writer };
        return out;
    }

    fn begin_object(out: *Out) Failure!void {
        out.json.beginObject() catch return no_memory(out.ctx);
    }

    fn end_object(out: *Out) Failure!void {
        out.json.endObject() catch return no_memory(out.ctx);
    }

    fn begin_array(out: *Out) Failure!void {
        out.json.beginArray() catch return no_memory(out.ctx);
    }

    fn end_array(out: *Out) Failure!void {
        out.json.endArray() catch return no_memory(out.ctx);
    }

    fn field(out: *Out, name: []const u8) Failure!void {
        out.json.objectField(name) catch return no_memory(out.ctx);
    }

    fn value(out: *Out, v: anytype) Failure!void {
        out.json.write(v) catch return no_memory(out.ctx);
    }

    /// A member with a value: `"name": v`.
    fn member(out: *Out, name: []const u8, v: anytype) Failure!void {
        try out.field(name);
        try out.value(v);
    }

    /// A diagnostic as api.md shows it: no `docs` member, because both `more` and `docs` are
    /// derived from the code by whoever renders it.
    fn diagnostic(out: *Out, source: *Diagnostic) Failure!void {
        source.docs = .{};
        var text: std.Io.Writer.Allocating = .init(out.ctx.arena);
        zigbox.diagnostic.write_json(&text.writer, source) catch return no_memory(out.ctx);
        const written = text.written();
        assert(written[written.len - 1] == '\n');
        try out.raw(written[0 .. written.len - 1]);
    }

    fn raw(out: *Out, text: []const u8) Failure!void {
        out.json.beginWriteRaw() catch return no_memory(out.ctx);
        out.json.writer.writeAll(text) catch return no_memory(out.ctx);
        out.json.endWriteRaw();
    }

    fn finish(out: *Out) Failure!Reply {
        const body = out.buffer.toOwnedSlice() catch return no_memory(out.ctx);
        if (body.len > constants.api_response_bytes_max) return no_memory(out.ctx);
        return .{ .body = body };
    }
};

// ---- The query string -------------------------------------------------------------------

const Param = struct { key: []const u8, value: []const u8 };

const Query = struct {
    params: [constants.api_query_params_max]Param = undefined,
    count: u32 = 0,

    fn parse(ctx: *const Context, text: []const u8) Failure!Query {
        var query: Query = .{};
        var pairs = std.mem.splitScalar(u8, text, '&');
        while (pairs.next()) |pair| {
            if (pair.len == 0) continue;
            if (query.count == constants.api_query_params_max) {
                return bad_request(ctx, "query", "has too many parameters");
            }
            const equals = std.mem.indexOfScalar(u8, pair, '=');
            const raw_key = if (equals) |at| pair[0..at] else pair;
            const raw_value = if (equals) |at| pair[at + 1 ..] else "";
            query.params[query.count] = .{
                .key = try decode(ctx, raw_key),
                .value = try decode(ctx, raw_value),
            };
            query.count += 1;
        }
        return query;
    }

    /// Fails on a parameter the endpoint does not take.
    fn allow(query: *const Query, ctx: *const Context, names: []const []const u8) Failure!void {
        for (query.params[0..query.count]) |param| {
            var known = false;
            for (names) |name| {
                if (std.mem.eql(u8, name, param.key)) known = true;
            }
            if (!known) return bad_request(ctx, param.key, "this endpoint takes no such parameter");
        }
    }

    /// The value of a parameter that may appear once; null if absent.
    fn one(query: *const Query, ctx: *const Context, name: []const u8) Failure!?[]const u8 {
        var found: ?[]const u8 = null;
        for (query.params[0..query.count]) |param| {
            if (!std.mem.eql(u8, param.key, name)) continue;
            if (found != null) return bad_request(ctx, name, "may be given only once");
            found = param.value;
        }
        return found;
    }

    fn number(query: *const Query, ctx: *const Context, name: []const u8) Failure!?u64 {
        const text = try query.one(ctx, name) orelse return null;
        return std.fmt.parseInt(u64, text, 10) catch bad_request(ctx, name, "is not a number");
    }

    fn flag(query: *const Query, ctx: *const Context, name: []const u8) Failure!bool {
        const text = try query.one(ctx, name) orelse return false;
        if (std.mem.eql(u8, text, "true")) return true;
        if (std.mem.eql(u8, text, "1")) return true;
        if (std.mem.eql(u8, text, "false")) return false;
        if (std.mem.eql(u8, text, "0")) return false;
        return bad_request(ctx, name, "must be true, false, 1 or 0");
    }
};

/// Percent-decodes into the arena. '+' stays a plus: no key or id has a space.
fn decode(ctx: *const Context, text: []const u8) Failure![]const u8 {
    const out = ctx.arena.alloc(u8, text.len) catch return no_memory(ctx);
    var length: usize = 0;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (text[index] != '%') {
            out[length] = text[index];
            length += 1;
            continue;
        }
        const problem = "has a '%' that is not followed by two hex digits";
        if (index + 3 > text.len) return bad_request(ctx, "query", problem);
        const high = std.fmt.charToDigit(text[index + 1], 16) catch
            return bad_request(ctx, "query", problem);
        const low = std.fmt.charToDigit(text[index + 2], 16) catch
            return bad_request(ctx, "query", problem);
        out[length] = high * 16 + low;
        length += 1;
        index += 2;
    }
    return out[0..length];
}

// ---- Values: JSON, with secrets taken out ---------------------------------------------

/// Writes a key's value as JSON: parsed and written back compactly, so a value that is not JSON
/// cannot corrupt the response (it becomes a string), and with `env` values removed for a
/// read-only token.
fn write_value(api: *const Api, out: *Out, key: []const u8, bytes: []const u8) Failure!void {
    var parsed = std.json.parseFromSliceLeaky(std.json.Value, out.ctx.arena, bytes, .{}) catch {
        return out.value(bytes);
    };
    const secret = std.mem.startsWith(u8, key, records.prefix_services) or
        std.mem.startsWith(u8, key, records.prefix_replicas);
    if (api.read_only and secret) redact_env(&parsed);
    if (api.read_only and std.mem.startsWith(u8, key, records.prefix_jobs)) redact_env(&parsed);
    if (api.read_only and std.mem.startsWith(u8, key, records.prefix_job_runs)) {
        redact_env(&parsed);
        if (parsed == .object) {
            if (parsed.object.getPtr("input_digest")) |digest| digest.* = .null;
        }
    }
    if (api.read_only and std.mem.startsWith(u8, key, records.prefix_job_input)) {
        if (parsed == .object) {
            if (parsed.object.getPtr("base64")) |input| input.* = .null;
        }
    }
    try out.value(parsed);
}

/// `"env": [["KEY", "value"]]` becomes `[["KEY", null]]`.
fn redact_env(value: *std.json.Value) void {
    if (value.* != .object) return;
    const env = value.object.getPtr("env") orelse return;
    if (env.* != .array) return;
    for (env.array.items) |*pair| {
        if (pair.* != .array) continue;
        if (pair.array.items.len < 2) continue;
        pair.array.items[1] = .null;
    }
}

fn write_kv(api: *const Api, out: *Out, kv: store.KeyValue, deleted: bool) Failure!void {
    try out.begin_object();
    try out.member("key", kv.key);
    try out.field("value");
    if (deleted) try out.value(null) else try write_value(api, out, kv.key, kv.value);
    try out.member("create_revision", if (deleted) 0 else kv.create_revision);
    try out.member("mod_revision", kv.mod_revision);
    try out.member("lease", if (deleted) 0 else kv.lease);
    try out.end_object();
}

// ---- Endpoints ---------------------------------------------------------------------------

const watch_events_max: u32 = 256;
const watch_batches_max: u32 = 64;
const list_limit_default: u64 = 100;

const Call = struct {
    api: *Api,
    hold: bool,
    ctx: *const Context,
    query: *const Query,
    parts: *Parts,

    fn no_more(call: Call) Failure!void {
        if (call.parts.next() != null) return no_such(call.ctx, "that path");
    }

    // ---- /v1/status ----

    /// Answers even when the store is down: the store's failure is part of the answer, so the
    /// console can tell "server down" from "store down".
    fn status(call: Call) Failure!Reply {
        const ctx = call.ctx;
        try call.query.allow(ctx, &.{});
        try call.no_more();
        const out = Out.create(ctx) catch return no_memory(ctx);
        try out.begin_object();
        try out.field("server");
        try out.begin_object();
        try out.member("version", call.api.version);
        try out.member("started_at_ms", call.api.started_at_ms);
        try out.end_object();
        try out.field("store");
        const store_ok = try call.store_state(out);
        if (store_ok) try findings(ctx, out);
        try out.member("time_ms", ctx.clock.now_ms());
        try out.end_object();
        return out.finish();
    }

    /// The allocation auditor's open findings (`/audit/allocations/`), present while the store
    /// answers. A listing that fails leaves the member out; the store's state says why.
    fn findings(ctx: *const Context, out: *Out) Failure!void {
        const open = controller.list_all(
            records.Audit,
            ctx,
            records.prefix_audit_allocations,
            null,
            constants.nodes_max,
        ) catch {
            ctx.diag.reset();
            return;
        };
        try out.field("findings");
        try out.begin_array();
        for (open.items) |entry| {
            try out.value(Finding{
                .node = entry.kv.key[records.prefix_audit_allocations.len..],
                .recorded = entry.rec.recorded,
                .reconstructed = entry.rec.reconstructed,
                .revision = entry.rec.revision,
                .decision = entry.rec.decision,
            });
        }
        try out.end_array();
    }

    /// The guard's pair and whether it could be saved. Members are added only when there is a
    /// guard; `remembered_save_failed` is a `ZC-E0216` diagnostic, present only while saving fails.
    fn remembered_state(call: Call, out: *Out) Failure!void {
        const guard = call.api.verified orelse return;
        try out.field("remembered");
        try pair_json(call.ctx, out, guard.remembered());
        if (!guard.save_trouble()) return;
        try out.field("remembered_save_failed");
        var note: Diag = undefined;
        note.reset();
        _ = failures.not_saved(&note) catch {};
        var diagnostic: Diagnostic = undefined;
        diag_mod.to_diagnostic(&diagnostic, &note);
        try out.diagnostic(&diagnostic);
    }

    /// Writes the store's state; returns whether the store answered.
    fn store_state(call: Call, out: *Out) Failure!bool {
        const ctx = call.ctx;
        try out.begin_object();
        try out.member("backend", call.api.backend);
        if (ctx.store.status(ctx.diag)) |state| {
            try out.member("ok", true);
            try out.member("revision", state.revision);
            try out.member("compacted_revision", state.compacted_revision);
            try call.remembered_state(out);
            try out.end_object();
            return true;
        } else |_| {
            try out.member("ok", false);
            try out.field("diagnostic");
            var diagnostic: Diagnostic = undefined;
            diag_mod.to_diagnostic(&diagnostic, ctx.diag);
            try out.diagnostic(&diagnostic);
            ctx.diag.reset();
        }
        try out.end_object();
        return false;
    }

    // ---- /v1/stats/pull ----

    /// `GET /v1/stats/pull[?node=NAME][&limit=N]`: the recorded pulls (`/pulls/`), newest first.
    /// Advisory records: one that does not decode or is from a newer version is counted in
    /// `skipped`, not an error. A read stops at `pulls_read_max` records (ascending by node) and
    /// says `truncated`, so a large cluster gets part of the picture, never a failure.
    fn stats(call: Call) Failure!Reply {
        const ctx = call.ctx;
        const kind = call.parts.next() orelse return no_such(ctx, "/v1/stats");
        if (!std.mem.eql(u8, kind, "pull")) return no_such(ctx, "/v1/stats/...");
        try call.no_more();
        try call.query.allow(ctx, &.{ "node", "limit" });
        const limit = try call.query.number(ctx, "limit") orelse pulls_limit_default;
        if (limit == 0 or limit > constants.api_list_limit_max) {
            return bad_request(ctx, "limit", "must be from 1 to 500");
        }
        var prefix: []const u8 = records.prefix_pulls;
        if (try call.query.one(ctx, "node")) |node| {
            if (records.name_problem(node, constants.node_name_bytes_max) != null) {
                return bad_request(ctx, "node", "is not a node name");
            }
            prefix = records.pull_prefix(node).slice();
        }
        var skipped: u32 = 0;
        var truncated = false;
        const found = controller.list_capped_tolerant(
            records.Pull,
            ctx,
            prefix,
            constants.pulls_read_max,
            &skipped,
            &truncated,
        ) catch return propagate(ctx);
        const order = ctx.arena.alloc(u32, found.items.len) catch return no_memory(ctx);
        for (order, 0..) |*slot, at| slot.* = @intCast(at);
        std.mem.sort(u32, order, found.items, pull_newer);
        const out = Out.create_sized(ctx, constants.pulls_response_bytes) catch
            return no_memory(ctx);
        try out.begin_object();
        try out.field("pulls");
        try out.begin_array();
        for (order[0..@min(order.len, limit)]) |at| try out.value(found.items[at].rec);
        try out.end_array();
        try out.member("skipped", skipped);
        try out.member("matched", found.items.len);
        try out.member("truncated", truncated);
        try out.member("revision", found.revision);
        try out.end_object();
        return out.finish();
    }

    fn pull_newer(items: []const controller.Entry(records.Pull), a: u32, b: u32) bool {
        const left = items[a].rec.finished_at_ms;
        const right = items[b].rec.finished_at_ms;
        if (left != right) return left > right;
        return std.mem.lessThan(u8, items[a].kv.key, items[b].kv.key);
    }

    // ---- /v1/list ----

    fn list(call: Call) Failure!Reply {
        const ctx = call.ctx;
        try call.query.allow(ctx, &.{ "prefix", "at", "limit", "continue", "reverse" });
        try call.no_more();
        const prefix = try call.query.one(ctx, "prefix") orelse "";
        if (store.prefix_problem(prefix) != null) {
            return bad_request(ctx, "prefix", "must be empty or start with '/' and be printable");
        }
        const at = try call.query.number(ctx, "at");
        const limit = try call.query.number(ctx, "limit") orelse list_limit_default;
        if (limit == 0 or limit > constants.api_list_limit_max) {
            return bad_request(ctx, "limit", "must be from 1 to 500");
        }
        const after = try call.query.one(ctx, "continue");
        if (after != null and at == null) {
            return bad_request(ctx, "continue", "needs `at`, the revision of the first page");
        }
        const page = ctx.store.list(ctx.arena, .{
            .prefix = prefix,
            .at_revision = at,
            .limit = @intCast(limit),
            .continue_after = after,
            .reverse = try call.query.flag(ctx, "reverse"),
        }, ctx.diag) catch return propagate(ctx);
        return call.list_body(page);
    }

    fn list_body(call: Call, page: store.ListResult) Failure!Reply {
        const out = Out.create(call.ctx) catch return no_memory(call.ctx);
        try out.begin_object();
        try out.member("revision", page.revision);
        try out.field("kvs");
        try out.begin_array();
        for (page.kvs) |kv| try write_kv(call.api, out, kv, false);
        try out.end_array();
        try out.member("continue", page.continue_after);
        try out.end_object();
        return out.finish();
    }

    // ---- /v1/watch ----

    fn watch(call: Call) Failure!Reply {
        const ctx = call.ctx;
        try call.query.allow(ctx, &.{ "prefix", "from", "timeout" });
        try call.no_more();
        const from = try call.query.number(ctx, "from") orelse
            return bad_request(ctx, "from", "is required: the revision to resume from");
        if (from == 0) return bad_request(ctx, "from", "must be at least 1");
        const timeout_max: u64 = constants.api_watch_timeout_ms_max;
        const timeout = try call.query.number(ctx, "timeout") orelse timeout_max;
        if (timeout > constants.api_watch_timeout_ms_max) {
            return bad_request(ctx, "timeout", "must be at most 25000");
        }
        const wanted = try call.prefix_params();
        const head = ctx.store.status(ctx.diag) catch return propagate(ctx);
        var open = ctx.store.watch(.{ .prefix = "", .from_revision = from }, ctx.diag) catch
            return propagate(ctx);
        defer open.close();
        return call.watch_body(&open, head.revision, wanted, @intCast(timeout));
    }

    /// The `prefix` parameters, each of which may repeat; none means every key.
    fn prefix_params(call: Call) Failure![]const []const u8 {
        const ctx = call.ctx;
        var found: std.ArrayList([]const u8) = .empty;
        for (call.query.params[0..call.query.count]) |param| {
            if (!std.mem.eql(u8, param.key, "prefix")) continue;
            if (store.prefix_problem(param.value) != null) {
                return bad_request(ctx, "prefix", "must be empty or start with '/'");
            }
            if (found.items.len == constants.api_watch_prefixes_max) {
                return bad_request(ctx, "prefix", "may be given at most 8 times");
            }
            found.append(ctx.arena, param.value) catch return no_memory(ctx);
        }
        return found.items;
    }

    /// Reads what is ready up to the revision the store was at when the request began, keeps the
    /// events under the requested prefixes, and writes them with the bookmark. A revision's
    /// events are never split: a batch that would pass the event limit waits for the next call.
    fn watch_body(
        call: Call,
        open: *store.Watch,
        head: store.Revision,
        prefixes: []const []const u8,
        timeout_ms: u32,
    ) Failure!Reply {
        const ctx = call.ctx;
        const read = try call.watch_read(open, head, prefixes);
        const out = Out.create(ctx) catch return no_memory(ctx);
        try out.begin_object();
        try out.member("revision", read.bookmark);
        try out.field("events");
        try out.begin_array();
        for (read.events) |event| {
            try out.begin_object();
            try out.member("type", @tagName(event.kind));
            try out.field("kv");
            try write_kv(call.api, out, event.kv, event.kind == .delete);
            try out.end_object();
        }
        try out.end_array();
        try out.end_object();
        const events: u32 = @intCast(read.events.len); // At most 64 batches of 256 events.
        return call.held(try out.finish(), events, read.bookmark, head, prefixes, timeout_ms);
    }

    const WatchRead = struct { events: []const store.Event, bookmark: store.Revision };

    /// The batches ready now, up to `head`, under the prefixes: the events and the bookmark.
    fn watch_read(
        call: Call,
        open: *store.Watch,
        head: store.Revision,
        prefixes: []const []const u8,
    ) Failure!WatchRead {
        const ctx = call.ctx;
        var events: std.ArrayList(store.Event) = .empty;
        var bookmark = open.delivered;
        for (0..watch_batches_max) |_| {
            if (bookmark >= head) break;
            const batch = open.next(ctx.arena, 0, ctx.diag) catch return propagate(ctx);
            const kept = filter(ctx, batch.events, prefixes) catch return no_memory(ctx);
            if (events.items.len > 0 and events.items.len + kept.len > watch_events_max) break;
            events.appendSlice(ctx.arena, kept) catch return no_memory(ctx);
            bookmark = batch.revision;
        }
        return .{ .events = events.items, .bookmark = bookmark };
    }

    /// An answer with no event is held until a change under `prefixes` or the timeout, but only
    /// when the bookmark has reached `head`: a watch that is still behind (the read stops after
    /// `watch_batches_max` batches, and a prefix or label may drop them all) answers at once, so
    /// the client comes back from the new bookmark instead of waiting for an unrelated write.
    fn held(
        call: Call,
        reply_in: Reply,
        events: u32,
        bookmark: store.Revision,
        head: store.Revision,
        prefixes: []const []const u8,
        timeout_ms: u32,
    ) Reply {
        var reply = reply_in;
        if (events == 0 and bookmark >= head and call.hold and timeout_ms > 0) {
            reply.hold_ms = timeout_ms;
            reply.hold_prefixes = prefixes;
        }
        return reply;
    }

    // ---- /v1/jobs/watch ----

    /// `/v1/watch` over `/job-status/`, the values decoded to job statuses (docs/api.md). A
    /// batch whose events all fall to `label` still advances the bookmark.
    fn jobs_watch(call: Call) Failure!Reply {
        const ctx = call.ctx;
        try call.query.allow(ctx, &.{ "from", "timeout", "label" });
        try call.no_more();
        const from = try call.query.number(ctx, "from") orelse
            return bad_request(ctx, "from", "is required: the revision to resume from");
        if (from == 0) return bad_request(ctx, "from", "must be at least 1");
        const timeout = try call.query.number(ctx, "timeout") orelse
            constants.api_watch_timeout_ms_max;
        if (timeout > constants.api_watch_timeout_ms_max) {
            return bad_request(ctx, "timeout", "must be at most 25000");
        }
        const label = try call.query.one(ctx, "label");
        const prefixes: []const []const u8 = &.{records.prefix_job_status};
        const head = ctx.store.status(ctx.diag) catch return propagate(ctx);
        var open = ctx.store.watch(.{ .prefix = "", .from_revision = from }, ctx.diag) catch
            return propagate(ctx);
        defer open.close();
        const read = try call.watch_read(&open, head.revision, prefixes);
        const events = job_api.watch_events(ctx, read.events, label) catch return propagate(ctx);
        const out = Out.create(ctx) catch return no_memory(ctx);
        out.json.options.emit_null_optional_fields = false;
        try out.begin_object();
        try out.member("revision", read.bookmark);
        try out.member("events", events);
        try out.end_object();
        return call.held(
            try out.finish(),
            @intCast(events.len), // At most 64 batches of 256 events.
            read.bookmark,
            head.revision,
            prefixes,
            @intCast(timeout),
        );
    }

    // ---- /v1/leases ----

    fn leases(call: Call) Failure!Reply {
        const ctx = call.ctx;
        try call.query.allow(ctx, &.{});
        try call.no_more();
        const listed = ctx.store.lease_list(ctx.arena, ctx.diag) catch return propagate(ctx);
        const out = Out.create(ctx) catch return no_memory(ctx);
        try out.begin_object();
        try out.member("time_ms", ctx.clock.now_ms());
        try out.field("leases");
        try out.begin_array();
        for (listed) |lease| {
            try out.begin_object();
            try out.member("id", lease.id);
            try out.member("ttl_ms", lease.ttl_ms);
            try out.member("remaining_ms", lease.remaining_ms);
            try out.member("keys", lease.keys);
            try out.end_object();
        }
        try out.end_array();
        try out.end_object();
        return out.finish();
    }

    // ---- /v1/why/{kind}/{name} ----

    fn why(call: Call) Failure!Reply {
        const ctx = call.ctx;
        try call.query.allow(ctx, &.{"decision"});
        const kind_text = call.parts.next() orelse return no_such(ctx, "/v1/why");
        const name = call.parts.next() orelse return no_such(ctx, "/v1/why/<kind>");
        try call.no_more();
        const kind = std.meta.stringToEnum(records.SubjectKind, kind_text) orelse
            return no_such(ctx, "/v1/why/<kind>: kind is service, replica, node or job");
        if (records.name_problem(name, constants.node_name_bytes_max) != null) {
            return bad_request(ctx, "name", "is not a valid name");
        }
        const decision = try call.query.one(ctx, "decision");
        if (decision) |id| {
            if (records.decision_id_time(id) == null) {
                return bad_request(ctx, "decision", "is not a decision id");
            }
        }
        const result = why_mod.why(ctx, .{ .kind = kind, .name = name }, decision) catch
            return propagate(ctx);
        const out = Out.create(ctx) catch return no_memory(ctx);
        out.json.options.emit_null_optional_fields = false;
        try out.value(result);
        return out.finish();
    }

    // ---- Writes: POST /v1/apply and DELETE /v1/services/{name} ----

    /// POST /v1/store/accept-rollback?confirm=true: the operator's decision to keep the store as
    /// it is (`store_verified.zig`). Answers the pair forgotten and the pair remembered now.
    fn accept_rollback(call: Call) Failure!Reply {
        const ctx = call.ctx;
        const name = call.parts.next() orelse return no_such(ctx, "/v1/store");
        if (!std.mem.eql(u8, name, "accept-rollback")) return no_such(ctx, "/v1/store/<name>");
        try call.query.allow(ctx, &.{"confirm"});
        try call.no_more();
        if (!try call.query.flag(ctx, "confirm")) {
            return bad_request(
                ctx,
                "confirm",
                "is required: pass --confirm after looking at the store",
            );
        }
        const verified = call.api.verified orelse
            return bad_request(
                ctx,
                "store",
                "this server does not check for a store that went backwards",
            );
        const accepted = verified.accept(ctx.diag) catch return propagate(ctx);
        const out = Out.create(ctx) catch return no_memory(ctx);
        try out.begin_object();
        try out.member("accepted", true);
        try out.field("old");
        try pair_json(ctx, out, accepted.old);
        try out.field("new");
        try pair_json(ctx, out, accepted.new);
        try out.end_object();
        return out.finish();
    }

    // ---- GET /v1/check/allocations and POST /v1/repair/allocations/{node} ----

    /// Every node's accounting reconstructed at one revision (`allocations.zig`). Writes nothing.
    fn check_allocations(call: Call) Failure!Reply {
        const ctx = call.ctx;
        const what = call.parts.next() orelse return no_such(ctx, "/v1/check");
        if (!std.mem.eql(u8, what, "allocations")) return no_such(ctx, "/v1/check/<name>");
        try call.query.allow(ctx, &.{});
        try call.no_more();
        const reconstruction = accounting.reconstruct(ctx) catch return propagate(ctx);
        const out = Out.create(ctx) catch return no_memory(ctx);
        out.json.options.emit_null_optional_fields = true;
        try out.begin_object();
        try out.member("revision", reconstruction.revision);
        var inconsistent: u32 = 0;
        try out.field("nodes");
        try out.begin_array();
        for (reconstruction.nodes) |*tally| {
            if (!tally.consistent()) inconsistent += 1;
            try out.value(CheckNode{
                .node = tally.node,
                .recorded = tally.recorded,
                .reconstructed = tally.reconstructed,
                .consistent = tally.consistent(),
                .finding = if (tally.finding) |finding| .{
                    .decision = finding.rec.decision,
                    .revision = finding.rec.revision,
                } else null,
            });
        }
        try out.end_array();
        try out.member("inconsistent", inconsistent);
        try out.end_object();
        return out.finish();
    }

    /// POST /v1/repair/allocations/{node}?confirm=true: the scheduler's `repair_allocation`, run
    /// in the request. Refused with ZC-E0402 when the node has no open finding, and with
    /// ZC-E0401, saying what it would write, without `confirm`.
    fn repair_allocation(call: Call, id: []const u8) Failure!Reply {
        const ctx = call.ctx;
        const what = call.parts.next() orelse return no_such(ctx, "/v1/repair");
        if (!std.mem.eql(u8, what, "allocations")) return no_such(ctx, "/v1/repair/<name>");
        const node = call.parts.next() orelse return no_such(ctx, "/v1/repair/allocations");
        try call.no_more();
        try call.query.allow(ctx, &.{"confirm"});
        if (records.name_problem(node, constants.node_name_bytes_max) != null) {
            return bad_request(ctx, "node", "is not a node name");
        }
        const confirmed = try call.query.flag(ctx, "confirm");
        for (0..apply_attempts_max) |_| {
            const plan = accounting.reconstruct(ctx) catch return propagate(ctx);
            const tally = open_finding(plan.nodes, node) orelse return no_finding(ctx, node);
            if (!confirmed) return unconfirmed(ctx, tally);
            const result = accounting.repair(ctx, &call.api.source, node, id) catch
                return propagate(ctx);
            switch (result) {
                .repaired => |done| {
                    const out = Out.create(ctx) catch return no_memory(ctx);
                    try out.value(RepairReply{
                        .request_id = id,
                        .node = node,
                        .action = accounting.repair_action,
                        .recorded = done.recorded,
                        .reconstructed = done.reconstructed,
                        .revision = done.revision,
                        .decision = done.decision,
                    });
                    return out.finish();
                },
                .no_finding => return no_finding(ctx, node),
                .conflict => {},
            }
        }
        ctx.diag.raise(.E0403);
        ctx.diag.cause("the accounting of {s} kept changing during the request", .{node});
        ctx.diag.fix_with("run it again", "zcube repair allocations {s} --confirm", .{node});
        return error.Failed;
    }

    fn write_post(call: Call, first: []const u8, body: []const u8, id: []const u8) Failure!Reply {
        const ctx = call.ctx;
        if (std.mem.eql(u8, first, "store")) return call.accept_rollback();
        if (std.mem.eql(u8, first, "repair")) return call.repair_allocation(id);
        if (std.mem.eql(u8, first, "jobs")) return call.jobs_post(body, id);
        if (!std.mem.eql(u8, first, "apply")) {
            const where = "POST is accepted at /v1/apply, /v1/jobs, /v1/store and /v1/repair";
            return bad_request(ctx, "method", where);
        }
        try call.query.allow(ctx, &.{"dry_run"});
        try call.no_more();
        const dry_run = try call.query.flag(ctx, "dry_run");
        const input = try apply_input(ctx, body, id);
        if (dry_run) {
            const planned = apply_mod.plan(ctx, input) catch return propagate(ctx);
            const action = if (planned.existing == null)
                "create"
            else if (planned.unchanged) "none" else "update";
            return write_reply(ctx, .{
                .request_id = id,
                .dry_run = true,
                .action = action,
                .name = input.name,
                .generation = planned.generation,
                .change = planned.change,
            });
        }
        for (0..apply_attempts_max) |_| {
            const result = apply_mod.apply(ctx, &call.api.source, input) catch
                return propagate(ctx);
            switch (result) {
                .written => |done| return write_reply(ctx, .{
                    .request_id = id,
                    .dry_run = false,
                    .action = if (done.created) "create" else "update",
                    .name = input.name,
                    .generation = done.generation,
                    .change = done.change,
                    .revision = done.revision,
                    .decision = done.decision,
                }),
                .unchanged => return write_reply(ctx, .{
                    .request_id = id,
                    .dry_run = false,
                    .action = "none",
                    .name = input.name,
                    .change = "no change",
                }),
                .conflict => {},
            }
        }
        return conflict(ctx, input.name);
    }

    fn write_delete(call: Call, first: []const u8, id: []const u8) Failure!Reply {
        const ctx = call.ctx;
        if (!std.mem.eql(u8, first, "services")) {
            return bad_request(ctx, "method", "DELETE is accepted at /v1/services/{name} only");
        }
        try call.query.allow(ctx, &.{"applied_by"});
        const name = call.parts.next() orelse return no_such(ctx, "/v1/services");
        try call.no_more();
        const by = try call.query.one(ctx, "applied_by") orelse anonymous;
        try check_applied_by(ctx, by);
        for (0..apply_attempts_max) |_| {
            const result = apply_mod.delete_service(ctx, &call.api.source, name, by, id) catch
                return propagate(ctx);
            switch (result) {
                .written => |done| return write_reply(ctx, .{
                    .request_id = id,
                    .dry_run = false,
                    .action = "delete",
                    .name = name,
                    .change = done.change,
                    .revision = done.revision,
                    .decision = done.decision,
                }),
                .unchanged => unreachable, // `delete_service` never reports "unchanged".
                .conflict => {},
            }
        }
        return conflict(ctx, name);
    }

    // ---- /v1/jobs ----

    fn jobs_post(call: Call, body: []const u8, id: []const u8) Failure!Reply {
        const ctx = call.ctx;
        try call.query.allow(ctx, &.{});
        const name = call.parts.next();
        if (name == null) return call.job_create(body, id);
        const verb = call.parts.next() orelse return no_such(ctx, "/v1/jobs/<name>");
        try call.no_more();
        if (!std.mem.eql(u8, verb, "cancel")) return no_such(ctx, "/v1/jobs/<name>/<verb>");
        return call.job_cancel(name.?, body, id);
    }

    fn job_create(call: Call, body: []const u8, id: []const u8) Failure!Reply {
        const ctx = call.ctx;
        const input = try job_input(ctx, body, id);
        for (0..apply_attempts_max) |_| {
            const result = job_api.create(ctx, &call.api.source, input) catch
                return propagate(ctx);
            switch (result) {
                .created => |done| return job_reply(ctx, 201, .{
                    .request_id = id,
                    .action = "create",
                    .name = input.name,
                    .state = .pending,
                    .revision = done.revision,
                    .decision = done.decision,
                }),
                .same => |old| return job_reply(ctx, 200, .{
                    .request_id = id,
                    .action = "none",
                    .name = old.name,
                    .state = job_api.current_state(ctx, old.name) catch return propagate(ctx),
                }),
                .conflict => {},
            }
        }
        return job_conflict(ctx, input.name);
    }

    fn job_cancel(call: Call, name: []const u8, body: []const u8, id: []const u8) Failure!Reply {
        const ctx = call.ctx;
        var by: []const u8 = anonymous;
        if (body.len > 0) {
            const parsed = std.json.parseFromSliceLeaky(CancelBody, ctx.arena, body, .{}) catch
                return bad_request(ctx, "body", "is not {\"applied_by\": \"...\"} or empty");
            by = parsed.applied_by;
        }
        try check_applied_by(ctx, by);
        for (0..apply_attempts_max) |_| {
            const result = job_api.cancel(ctx, &call.api.source, name, by, id) catch
                return propagate(ctx);
            switch (result) {
                .accepted => |done| return job_reply(ctx, 202, .{
                    .request_id = id,
                    .action = "cancel",
                    .name = name,
                    .state = done.state,
                    .revision = done.revision,
                    .decision = done.decision,
                }),
                .already => return job_reply(ctx, 202, .{
                    .request_id = id,
                    .action = "none",
                    .name = name,
                    .state = job_api.current_state(ctx, name) catch return propagate(ctx),
                }),
                .finished => |view| return job_reply(ctx, 200, .{
                    .request_id = id,
                    .action = "none",
                    .name = name,
                    .state = job_api.state_of(view.status),
                    .end = if (view.status) |known| known.end else null,
                }),
                .conflict => {},
            }
        }
        return job_conflict(ctx, name);
    }

    fn jobs_get(call: Call) Failure!Reply {
        const ctx = call.ctx;
        const name = call.parts.next() orelse return call.job_list();
        if (std.mem.eql(u8, name, job_api.reserved_name)) return call.jobs_watch();
        try call.no_more();
        try call.query.allow(ctx, &.{});
        const view = job_api.get(ctx, name) catch return propagate(ctx);
        const out = Out.create(ctx) catch return no_memory(ctx);
        out.json.options.emit_null_optional_fields = false;
        try out.begin_object();
        try out.member("revision", view.revision);
        try out.member("job", try JobSpec.of(ctx, view.job));
        try out.member("state", job_api.state_of(view.status));
        try out.member("status", view.status);
        try out.end_object();
        return out.finish();
    }

    fn job_list(call: Call) Failure!Reply {
        const ctx = call.ctx;
        try call.query.allow(ctx, &.{ "state", "label", "limit", "continue", "at" });
        var options: job_api.ListOptions = .{ .limit = 50 };
        if (try call.query.one(ctx, "state")) |text| {
            if (std.mem.eql(u8, text, "ended")) {
                options.ended = true;
            } else {
                options.state = std.meta.stringToEnum(records.JobState, text) orelse
                    return bad_request(ctx, "state", "is not a job state");
            }
        }
        options.label = try call.query.one(ctx, "label");
        if (try call.query.number(ctx, "limit")) |limit| {
            if (limit == 0 or limit > constants.api_list_limit_max) {
                return bad_request(ctx, "limit", "must be from 1 to 500");
            }
            options.limit = @intCast(limit);
        }
        options.at = try call.query.number(ctx, "at");
        options.after = try call.query.one(ctx, "continue");
        if (options.after != null and options.at == null) {
            return bad_request(ctx, "continue", "needs `at`, the revision of the first page");
        }
        const listing = job_api.list(ctx, options) catch return propagate(ctx);
        const out = Out.create(ctx) catch return no_memory(ctx);
        out.json.options.emit_null_optional_fields = false;
        try out.begin_object();
        try out.member("revision", listing.revision);
        try out.member("jobs", listing.rows);
        try out.member("continue", listing.continue_after);
        try out.end_object();
        return out.finish();
    }

    // ---- /v1/codes and /v1/explain/{code} ----

    fn codes_list(call: Call) Failure!Reply {
        const ctx = call.ctx;
        try call.query.allow(ctx, &.{});
        try call.no_more();
        const out = Out.create(ctx) catch return no_memory(ctx);
        try out.begin_object();
        try out.field("codes");
        try out.begin_array();
        for (codes.registry) |entry| {
            const name = codes.full_name(entry.code);
            try write_code(out, name, entry.severity, entry.blame, entry.summary, null);
        }
        for (zigbox.codes.registry) |entry| {
            const name = zigbox.codes.full_name(entry.code);
            try write_code(out, name, entry.severity, entry.blame, entry.summary, null);
        }
        for (runtime_codes.placeholders) |entry| {
            try write_code(out, entry.full_name, entry.severity, entry.blame, entry.summary, null);
        }
        try out.end_array();
        try out.end_object();
        return out.finish();
    }

    fn explain(call: Call) Failure!Reply {
        const ctx = call.ctx;
        try call.query.allow(ctx, &.{});
        const text = call.parts.next() orelse return no_such(ctx, "/v1/explain");
        try call.no_more();
        const buffer = ctx.arena.alloc(u8, constants.diag_output_bytes_max) catch
            return no_memory(ctx);
        const out = Out.create(ctx) catch return no_memory(ctx);
        if (std.mem.startsWith(u8, text, "ZC-")) {
            const code = codes.parse(text) orelse return unknown_code(ctx, text);
            const entry = codes.entry(code);
            const long = diag_mod.explain(code, buffer);
            const name = codes.full_name(code);
            try write_code(out, name, entry.severity, entry.blame, entry.summary, long);
        } else if (runtime_codes.find(text)) |entry| {
            const long = placeholder_text(entry, buffer);
            try write_code(out, entry.full_name, entry.severity, entry.blame, entry.summary, long);
        } else {
            const code = zigbox.codes.parse(text) orelse return unknown_code(ctx, text);
            const entry = zigbox.codes.entry(code);
            const long = zigbox.explain.render(code, buffer);
            const name = zigbox.codes.full_name(code);
            try write_code(out, name, entry.severity, entry.blame, entry.summary, long);
        }
        return out.finish();
    }
};

fn write_code(
    out: *Out,
    full_name: []const u8,
    severity: zigbox.codes.Severity,
    blame: zigbox.codes.Blame,
    summary: []const u8,
    explanation: ?[]const u8,
) Failure!void {
    try out.begin_object();
    try out.member("code", full_name);
    try out.member("severity", @tagName(severity));
    try out.member("blame", @tagName(blame));
    try out.member("summary", summary);
    if (explanation) |long| try out.member("explanation", long);
    try out.end_object();
}

/// What `explain` prints for a placeholder runtime code, laid out as every other code's.
fn placeholder_text(entry: *const runtime_codes.Entry, buffer: []u8) []const u8 {
    var exit_buffer: [zigbox.codes.exit_text_bytes_max]u8 = undefined;
    const exit_text = std.fmt.bufPrint(&exit_buffer, "{d}", .{codes.exit_code(entry.blame)});
    return zigbox.explain.render_entry(.{
        .full_name = entry.full_name,
        .severity = entry.severity,
        .blame = entry.blame,
        .summary = entry.summary,
        .explanation = entry.explanation,
        // Cannot fail: an exit code is at most three digits, and the buffer holds forty bytes.
        .exit_text = exit_text catch unreachable,
    }, buffer);
}

fn unknown_code(ctx: *const Context, text: []const u8) Failure {
    assert(ctx.diag.code == null);
    ctx.diag.raise(.E0101);
    ctx.diag.cause("no code {s} is registered", .{text});
    ctx.diag.fix(.{ .sentence = "list the codes", .command = "GET /v1/codes" });
    return error.Failed;
}

/// Keeps the events whose key starts with one of `prefixes` (all of them if there are none).
fn filter(
    ctx: *const Context,
    events: []const store.Event,
    prefixes: []const []const u8,
) Allocator.Error![]const store.Event {
    if (prefixes.len == 0) return events;
    var kept: std.ArrayList(store.Event) = .empty;
    for (events) |event| {
        for (prefixes) |prefix| {
            if (!std.mem.startsWith(u8, event.kv.key, prefix)) continue;
            try kept.append(ctx.arena, event);
            break;
        }
    }
    return kept.items;
}
