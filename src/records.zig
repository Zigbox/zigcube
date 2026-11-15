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
pub const prefix_node_store = "/node-store/";
pub const prefix_pulls = "/pulls/";
pub const prefix_summaries = "/decision-summaries/";
pub const prefix_replica_numbers = "/replica-numbers/";
pub const prefix_jobs = "/jobs/";
/// What the cause of ZC-E0523 says of a damaged input; the agent's client tells it from an
/// absent one by this. THIS TEXT IS WIRE PROTOCOL: the refusal carries no structured member
/// to tell the two apart, and an agent and a server of different versions meet during an
/// upgrade. Rewording it makes an old agent (or server) report a damaged input as absent.
/// Do not change it without a version bump of the agent API; `agent_client_test.zig` and
/// `agent_api_test.zig` pin the literal text on both sides.
pub const input_mismatch_phrase = "does not match its digest";

pub const prefix_job_input = "/job-input/";
pub const key_job_admission = "/job-admission";
pub const prefix_job_runs = "/job-runs/";
pub const prefix_job_status = "/job-status/";
pub const key_job_endings = "/job-endings";
pub const prefix_job_observed = "/job-observed/";

/// A job's run id: `<name>-job`. The last segment is not decimal, so it is never a replica id
/// (`<service>-<n>`), and it is a valid container name (docs/keys.md, "Jobs").
pub fn job_run_id(buffer: *[constants.job_run_id_bytes_max]u8, name: []const u8) []const u8 {
    assert(name_problem(name, constants.service_name_bytes_max) == null);
    @memcpy(buffer[0..name.len], name);
    @memcpy(buffer[name.len..][0..job_run_suffix.len], job_run_suffix);
    return buffer[0 .. name.len + job_run_suffix.len];
}

pub const job_run_suffix = "-job";

/// The job a run id names, or null if `id` is not a run id.
pub fn job_of_run(id: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, id, job_run_suffix)) return null;
    const name = id[0 .. id.len - job_run_suffix.len];
    if (name_problem(name, constants.service_name_bytes_max) != null) return null;
    return name;
}

pub fn job_key(name: []const u8) Key {
    assert(name_problem(name, constants.service_name_bytes_max) == null);
    return Key.build(&.{ prefix_jobs, name });
}

pub fn job_input_key(name: []const u8) Key {
    assert(name_problem(name, constants.service_name_bytes_max) == null);
    return Key.build(&.{ prefix_job_input, name });
}

pub fn job_run_key(name: []const u8) Key {
    assert(name_problem(name, constants.service_name_bytes_max) == null);
    return Key.build(&.{ prefix_job_runs, name });
}

pub fn job_status_key(name: []const u8) Key {
    assert(name_problem(name, constants.service_name_bytes_max) == null);
    return Key.build(&.{ prefix_job_status, name });
}

pub fn job_observed_prefix(node: []const u8) Key {
    assert(name_problem(node, constants.node_name_bytes_max) == null);
    return Key.build(&.{ prefix_job_observed, node, "/" });
}

pub fn job_observed_key(node: []const u8, name: []const u8) Key {
    assert(name_problem(node, constants.node_name_bytes_max) == null);
    assert(name_problem(name, constants.service_name_bytes_max) == null);
    return Key.build(&.{ prefix_job_observed, node, "/", name });
}

pub fn service_key(name: []const u8) Key {
    assert(name_problem(name, constants.service_name_bytes_max) == null);
    return Key.build(&.{ prefix_services, name });
}

pub fn replica_numbers_key(service: []const u8) Key {
    assert(name_problem(service, constants.service_name_bytes_max) == null);
    return Key.build(&.{ prefix_replica_numbers, service });
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

pub fn node_store_key(name: []const u8) Key {
    assert(name_problem(name, constants.node_name_bytes_max) == null);
    return Key.build(&.{ prefix_node_store, name });
}

/// `/pulls/<node>/<tree>`: the record of the last pull of a tree on a node.
pub fn pull_key(node: []const u8, tree: []const u8) Key {
    assert(name_problem(node, constants.node_name_bytes_max) == null);
    assert(tree.len > 0);
    assert(tree.len <= constants.tree_digest_bytes);
    return Key.build(&.{ prefix_pulls, node, "/", tree });
}

pub fn pull_prefix(node: []const u8) Key {
    assert(name_problem(node, constants.node_name_bytes_max) == null);
    return Key.build(&.{ prefix_pulls, node, "/" });
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

/// The prefix of every summary of one subject: `/decision-summaries/<kind>/<name>/`.
pub fn summary_prefix(kind: SubjectKind, name: []const u8) Key {
    assert(name_problem(name, constants.node_name_bytes_max) == null);
    return Key.build(&.{ prefix_summaries, @tagName(kind), "/", name, "/" });
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

// ---- Jobs (B1) -----------------------------------------------------------------------------

pub const JobLimits = struct {
    cpu_millis: ?u32 = null,
    memory_bytes: ?u64 = null,
    pids: ?u32 = null,
};

pub const JobCancel = struct { at_ms: u64, by: []const u8 = "" };

/// The relay a job asked for, resolved at admission from the server's configuration (B3): the
/// name the job wrote and the upstream address the configuration gave it then. A job never
/// carries an address of its own choosing.
pub const JobRelay = struct {
    name: []const u8,
    address: []const u8,
    /// B4: the DNS name the upstream's certificate must carry, and the 64 hex digits of the
    /// Ed25519 key that signs it (read from the configuration's `server_ca`). Empty on a job
    /// stored before B4: such a relay has no upstream to check and stays closed (fail closed).
    server_name: []const u8 = "",
    server_anchor: []const u8 = "",
    /// Test-only: the upstream is plain TCP, as in B3. The server accepts it only from a Debug
    /// build's configuration (`server_config.relay_plain_allowed`), never from a release one.
    plain: bool = false,
};

/// Where a job may run (B6): the node labels it requires, as key and value pairs with unique
/// keys. A node is a candidate only if it carries every pair (docs/keys.md, "Placement").
pub const Placement = struct {
    require: []const Pair = &.{},

    /// `{"require":{"key":"value"}}`: the shape the API takes and shows, and the record's.
    pub fn jsonStringify(placement: Placement, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("require");
        try jw.beginObject();
        for (placement.require) |pair| {
            try jw.objectField(pair[0]);
            try jw.write(pair[1]);
        }
        try jw.endObject();
        try jw.endObject();
    }

    /// Reads what `jsonStringify` writes. A member other than `require`, a value that is not a
    /// string or a key twice is an error: what the API accepts is checked before it is stored.
    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !Placement {
        if (.object_begin != try source.next()) return error.UnexpectedToken;
        var require: []const Pair = &.{};
        while (true) {
            const limit = options.max_value_len.?;
            const name = try source.nextAllocMax(allocator, .alloc_if_needed, limit);
            switch (name) {
                .object_end => return .{ .require = require },
                .string, .allocated_string => |text| {
                    if (!std.mem.eql(u8, text, "require")) return error.UnknownField;
                    if (require.len > 0) return error.DuplicateField;
                    require = try parse_require(allocator, source, options);
                },
                else => return error.UnexpectedToken,
            }
        }
    }

    fn parse_require(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) ![]const Pair {
        if (.object_begin != try source.next()) return error.UnexpectedToken;
        var pairs: std.ArrayList(Pair) = .empty;
        while (true) {
            const limit = options.max_value_len.?;
            const name = try source.nextAllocMax(allocator, .alloc_if_needed, limit);
            const key = switch (name) {
                .object_end => return pairs.items,
                .string, .allocated_string => |text| text,
                else => return error.UnexpectedToken,
            };
            for (pairs.items) |pair| {
                if (std.mem.eql(u8, pair[0], key)) return error.DuplicateField;
            }
            const value = try std.json.innerParse([]const u8, allocator, source, options);
            try pairs.append(allocator, .{ key, value });
        }
    }
};

/// The desired state of a job: the immutable spec, and the one mutable member, `cancel_requested`.
/// The input is never here, only its digest and size (`/job-input/<name>` holds it).
pub const Job = struct {
    v: u32 = 1,
    name: []const u8,
    image: []const u8,
    source: []const u8 = "",
    command: []const []const u8,
    env: []const Pair = &.{},
    limits: JobLimits = .{},
    deadline_ms: u64,
    /// Always 0 in B1; a larger value is refused (ZC-E0130).
    retries: u32 = 0,
    labels: []const Pair = &.{},
    grace_ms: u32 = 0,
    input_env: ?[]const u8 = null,
    input_digest: ?[]const u8 = null,
    input_bytes: ?u64 = null,
    /// B3: absent on every job stored before it (additive, same version).
    relay: ?JobRelay = null,
    /// B5: the job's DSSE envelopes, each one line of `zbx trust export`; absent when it has none
    /// and on every job stored before it (additive, same version).
    signatures: ?[]const []const u8 = null,
    /// B6: absent on every job stored before it and on a job that asks for none (additive, same
    /// version).
    placement: ?Placement = null,
    submit_by_ms: u64,
    created_at_ms: u64,
    applied_by: []const u8 = "",
    cancel_requested: ?JobCancel = null,
};

/// The input of a job, written once with the job. Held base64-encoded: the encoding of 64 KiB of
/// text always fits a store value, where JSON escaping of control characters might not.
pub const JobInput = struct {
    v: u32 = 1,
    base64: []const u8,
};

pub const HourCount = struct { hour: u64, count: u32 };

/// The aggregate every create rewrites (authority.md, "Predicates over sets"): jobs ever created
/// and creations per hour over the last `job_admission_window_h` hours, oldest first.
pub const JobAdmission = struct {
    v: u32 = 1,
    admitted: u64 = 0,
    hours: []const HourCount = &.{},
};

/// The aggregate every terminal status rewrites: how many jobs have ended, ever.
pub const JobEndings = struct {
    v: u32 = 1,
    ended: u64 = 0,
};

/// Why a run is stopped by the server (the first phase of an ending).
pub const RunStopCause = enum { cancel, @"unreachable", not_started };

pub const RunStop = struct {
    cause: RunStopCause,
    at_ms: u64,
};

/// What the agent runs: a job's spec without the input, with the server's start backstop.
pub const JobRun = struct {
    v: u32 = 1,
    id: []const u8,
    job: []const u8,
    image: []const u8,
    source: []const u8 = "",
    command: []const []const u8,
    env: []const Pair = &.{},
    limits: JobLimits = .{},
    deadline_ms: u64,
    grace_ms: u32 = 0,
    labels: []const Pair = &.{},
    input_env: ?[]const u8 = null,
    input_digest: ?[]const u8 = null,
    input_bytes: ?u64 = null,
    /// B3: the resolved relay of the job, absent when it asked for none.
    relay: ?JobRelay = null,
    /// B5: the job's signatures, for the node's own check; absent when it has none.
    signatures: ?[]const []const u8 = null,
    /// B6: the job's `placement`, which the scheduler reads when it places the run.
    placement: ?Placement = null,
    start_by_ms: u64,
    created_at_ms: u64,
    stop: ?RunStop = null,
};

pub const JobState = enum { pending, placed, running, exited, failed, cancelled };

pub fn job_state_terminal(state: JobState) bool {
    return switch (state) {
        .pending, .placed, .running => false,
        .exited, .failed, .cancelled => true,
    };
}

/// The closed set of causes of a `failed` ending (docs/keys.md, "Jobs").
pub const JobFailure = enum {
    oom,
    pid_limit,
    start_failed,
    deadline,
    fenced,
    @"unreachable",
    not_started,
    unknown,
    /// B5: the node's trust policy refused the run before it started (ZBX-E0905).
    refused,
};

/// How a job ended: `exited` carries exactly one of `code` and `signal`, `failed` a `cause`,
/// `cancelled` nothing.
pub const JobEnd = struct {
    kind: enum { exited, failed, cancelled },
    code: ?u8 = null,
    signal: ?u8 = null,
    cause: ?JobFailure = null,

    pub fn valid(end: JobEnd) bool {
        return switch (end.kind) {
            .exited => (end.code == null) != (end.signal == null) and end.cause == null,
            .failed => end.cause != null and end.code == null and end.signal == null,
            .cancelled => end.cause == null and end.code == null and end.signal == null,
        };
    }
};

/// Why an agent stopped a run on its own, recorded before it stops the container.
pub const StopCause = enum { cancel, deadline, fence, not_started, @"unreachable" };

pub const JobStatus = struct {
    v: u32 = 1,
    state: JobState,
    node: ?[]const u8 = null,
    /// The `/assigned/<node>/<run>` revision (the placement epoch) the run was claimed under.
    epoch: ?u64 = null,
    /// The `/nodes/<node>` revision of the tenure that claimed it.
    tenure: ?u64 = null,
    started_at_ms: ?u64 = null,
    ended_at_ms: ?u64 = null,
    end: ?JobEnd = null,
    stop_cause: ?StopCause = null,
    diagnostic: ?Raw = null,
    /// The id of the last decision about the job.
    decision: ?[]const u8 = null,
    reported_at_ms: u64,

    /// A terminal state carries its `end` and `ended_at_ms`; no other state carries either.
    pub fn valid(status: JobStatus) bool {
        const terminal = job_state_terminal(status.state);
        if (terminal != (status.end != null)) return false;
        if (terminal != (status.ended_at_ms != null)) return false;
        const end = status.end orelse return true;
        if (!end.valid()) return false;
        return switch (status.state) {
            .exited => end.kind == .exited,
            .failed => end.kind == .failed,
            .cancelled => end.kind == .cancelled,
            .pending, .placed, .running => false,
        };
    }
};

pub const JobObservedStatus = enum { claimed, running, stopped };

/// What an agent saw of a run, under its own record kind (not `Observed`, which is a replica's).
pub const JobObserved = struct {
    v: u32 = 1,
    run: []const u8,
    node: []const u8,
    tenure: u64,
    /// The `/assigned/<node>/<run>` revision it ran under.
    assignment: u64,
    status: JobObservedStatus,
    exit: ?Exit = null,
    stop_cause: ?StopCause = null,
    diagnostic: ?Raw = null,
    started_at_ms: ?u64 = null,
    reported_at_ms: u64,

    /// A `stopped` report says how the run ended, and no other report does: a claim and a running
    /// run have no exit yet, and a claim has not started.
    pub fn valid(observed: JobObserved) bool {
        return switch (observed.status) {
            .claimed => observed.exit == null and observed.started_at_ms == null,
            .running => observed.exit == null,
            .stopped => observed.exit != null,
        };
    }
};

/// Whether a job record's collections are within the bounds the API enforces. A row that fails
/// was not written through it.
pub fn job_shape_valid(command: []const []const u8, env: []const Pair, labels: []const Pair) bool {
    if (command.len == 0) return false;
    if (command.len > constants.job_command_words_max) return false;
    if (labels.len > constants.job_labels_max) return false;
    var env_bytes: usize = 0;
    for (env) |pair| env_bytes += pair[0].len + pair[1].len;
    return env_bytes <= constants.job_env_bytes_max;
}

fn job_valid(record: anytype) bool {
    return job_shape_valid(record.command, record.env, record.labels);
}

/// A replica's assignment names a service and no job; a run's is version 2 or later, names no
/// service, and its replica is the run id of its job. No other combination was written by us.
fn assigned_valid(record: Assigned) bool {
    const run = record.service.len == 0;
    if ((record.job != null) != run) return false;
    const job = record.job orelse return true;
    if (record.v < assigned_version_job) return false;
    return std.mem.eql(u8, job_of_run(record.replica) orelse return false, job);
}

fn admission_valid(record: JobAdmission) bool {
    if (record.hours.len > constants.job_admission_window_h + 1) return false;
    var sum: u64 = 0;
    for (record.hours, 0..) |entry, index| {
        if (index > 0 and entry.hour <= record.hours[index - 1].hour) return false;
        sum += entry.count;
    }
    return sum <= record.admitted;
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
    v: u32 = 3,
    name: []const u8,
    image: []const u8,
    replicas: u32,
    command: []const []const u8,
    env: []const Pair = &.{},
    limits: Limits = .{},
    generation: u64,
    /// A C0 record's counter, carried forward by `apply` only until `/replica-numbers/<service>`
    /// exists (the replica controller seeds it from this); absent for a service created later.
    next_replica: ?u64 = null,
    applied_by: []const u8 = "",
    request_id: []const u8 = "",
    /// The OCI reference `image` is pulled from, pinned by digest (docs/keys.md); empty when the
    /// tree must already be on the node. Absent in records before version 3.
    source: []const u8 = "",
};

/// The counter that keeps replica ids unique forever: the number the next replica takes.
pub const ReplicaNumber = struct {
    v: u32 = 1,
    next: u64,
};

/// What a service asks for, once per replica. Where it runs is `/assigned`'s (the scheduler's);
/// a v1 record's `node` and `requests` are ignored on read.
pub const Replica = struct {
    v: u32 = 3,
    id: []const u8,
    service: []const u8,
    generation: u64,
    image: []const u8,
    command: []const []const u8,
    env: []const Pair = &.{},
    limits: Limits = .{},
    /// The service's `source`, copied (absent before version 3).
    source: []const u8 = "",
};

/// Whether `replica` runs what `service` asks for now: the image, `source`, command, `env` and
/// `limits`, the inputs that bump a service's `generation`. The generation alone cannot say: it
/// restarts at 1 when a service is deleted and applied again, so a replica of the previous
/// incarnation can be ahead of the new service, or equal to it, and still run something else.
pub fn replica_runs_service(replica: *const Replica, service: *const Service) bool {
    if (!std.mem.eql(u8, replica.image, service.image)) return false;
    if (!std.mem.eql(u8, replica.source, service.source)) return false;
    if (!strings_equal(replica.command, service.command)) return false;
    if (!pairs_equal(replica.env, service.env)) return false;
    return limits_equal(replica.limits, service.limits);
}

pub fn strings_equal(first: []const []const u8, second: []const []const u8) bool {
    if (first.len != second.len) return false;
    for (first, second) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    return true;
}

pub fn pairs_equal(first: []const Pair, second: []const Pair) bool {
    if (first.len != second.len) return false;
    for (first, second) |left, right| {
        if (!std.mem.eql(u8, left[0], right[0])) return false;
        if (!std.mem.eql(u8, left[1], right[1])) return false;
    }
    return true;
}

pub fn limits_equal(first: Limits, second: Limits) bool {
    if (first.cpu_millis != second.cpu_millis) return false;
    return first.memory_bytes == second.memory_bytes;
}

pub const Node = struct {
    v: u32 = 1,
    name: []const u8,
    agent_version: []const u8 = "",
    address: []const u8 = "",
    capacity: Requests,
    labels: []const []const u8 = &.{},
    /// The path of the trust policy the node's agent checks every job's signatures against
    /// before it starts a run (`--trust-policy`, B5), published only when the policy asks for a
    /// signature or a provenance; empty: the agent checks nothing (as of its registration).
    trust_policy: []const u8 = "",
};

/// The value of the label `key` among a node's labels, which are `key=value` words (B6): the first
/// word with that key. A word with no `=` is a key with no value and is never matched.
pub fn node_label_value(labels: []const []const u8, key: []const u8) ?[]const u8 {
    for (labels) |label| {
        const at = std.mem.indexOfScalar(u8, label, '=') orelse continue;
        if (std.mem.eql(u8, label[0..at], key)) return label[at + 1 ..];
    }
    return null;
}

/// The node label whose value names the key a node is reserved by: `exclusive=tenant`.
pub const exclusive_label = "exclusive";

/// Null if a node's labels may be registered, else the sentence that says why not (B6): each
/// `exclusive=K` must name a key `K` that the node carries, once.
pub fn node_labels_problem(labels: []const []const u8) ?[]const u8 {
    for (labels) |label| {
        const at = std.mem.indexOfScalar(u8, label, '=') orelse continue;
        if (!std.mem.eql(u8, label[0..at], exclusive_label)) continue;
        const key = label[at + 1 ..];
        if (node_label_value(labels, key) == null) {
            return "an exclusive label names a key the node does not carry";
        }
        var carried: u32 = 0;
        for (labels) |other| {
            const eq = std.mem.indexOfScalar(u8, other, '=') orelse continue;
            if (std.mem.eql(u8, other[0..eq], key)) carried += 1;
        }
        if (carried > 1) return "an exclusive label names a key the node carries twice";
    }
    return null;
}

/// One tree a node holds completely, as its summary advertises it (docs/swarm.md): the tree's
/// digest, its size, and the bottom-K sketch of its chunks as hex (24 digits an entry: the key,
/// 8 bytes little endian, then the chunk's size, 4 bytes).
pub const HeldTree = struct {
    tree: []const u8,
    bytes: u64,
    chunks: u32,
    sample: []const u8 = "",
};

/// `/node-store/<node>`: what a node's store holds (docs/keys.md), written by the node's agent on
/// its lease, so the summary of a lost node goes with its registration. Advisory: the scheduler
/// reads it for locality and never compares it, because a stale summary costs speed, not
/// correctness (authority.md §2, owner decision O1, 2026-11-03).
pub const NodeStore = struct {
    v: u32 = 1,
    node: []const u8,
    /// The complete trees, most recently used first.
    trees: []const HeldTree = &.{},
    /// The Bloom filter over every chunk the node holds, as hex, for the fetching agents of
    /// slice 6. Empty when the node advertises none.
    filter: []const u8 = "",
    /// Chunks the filter was filled with.
    filter_chunks: u32 = 0,
    /// `HOST:PORT` the node's peer server answers on, for the fetching agents of other nodes;
    /// empty when the node serves no peers. (`/nodes/<node>`'s `address` is text for people.)
    peer: []const u8 = "",
    /// Trees the node holds but left out of `trees` (more than `summary_trees_max`).
    omitted: u32 = 0,
};

/// Bytes one peer gave a pull.
pub const PullPeer = struct { peer: []const u8, bytes: u64 };

/// `/pulls/<node>/<tree>`: what the last pull of a tree on a node moved, by source (docs/keys.md,
/// owner decision O6, C2 slice 7). Written by the node's agent from the fetch worker's report
/// and never read by a controller: it is statistics, so a missing or stale record can change
/// nothing but `zcube stats pull`. A later pull of the same tree replaces it.
pub const Pull = struct {
    v: u32 = 1,
    node: []const u8,
    /// The tree's digest as the pull was asked for it.
    tree: []const u8,
    /// Bytes the registry gave.
    registry_bytes: u64 = 0,
    /// Bytes each peer gave, by the peer's node name; a peer that gave none is left out.
    peer_bytes: []const PullPeer = &.{},
    /// Bytes the node already held, so nothing moved for them.
    cached_bytes: u64 = 0,
    started_at_ms: u64 = 0,
    finished_at_ms: u64 = 0,
    /// Peers the pull struck for a chunk that did not match its hash (ZC-W0601).
    bad_peers: []const []const u8 = &.{},
};

pub const ObservedStatus = enum { starting, running, stopped };

/// `refused` (B5) is a job's only: the node's trust policy refused the run before it started.
pub const ExitKind = enum { exited, signaled, oom, pid_limit, start_failed, lost, refused };

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

/// A replica's record never carries `refused`: only a job run is judged by the node's policy.
pub fn observed_valid(observed: *const Observed) bool {
    const exit = observed.exit orelse return true;
    return exit.kind != .refused;
}

/// The placement: the scheduler's decision to run a replica on a node.
pub const Assigned = struct {
    v: u32 = 2,
    replica: []const u8,
    /// The service a replica belongs to; empty for a run (version 2).
    service: []const u8 = "",
    requests: Requests,
    reason: []const u8,
    /// The job a run belongs to (version 2): set for `<name>-job` ids, absent for replicas. Every
    /// reader of `service` takes this branch for a run (`assigned_group`).
    job: ?[]const u8 = null,
};

/// Assignments are written at the oldest version that holds their members: version 2 only for a
/// run, so a replica's assignment stays readable by a build that predates jobs.
pub const assigned_version_plain: u32 = 1;
pub const assigned_version_job: u32 = 2;

/// A replica's assignment, at the version that a build predating jobs reads. Every site that places
/// a replica builds it here, so none leaves `v` at its default (the job version).
pub fn assigned_replica(
    replica: []const u8,
    service: []const u8,
    requests: Requests,
    reason: []const u8,
) Assigned {
    assert(service.len > 0);
    return .{
        .v = assigned_version_plain,
        .replica = replica,
        .service = service,
        .requests = requests,
        .reason = reason,
    };
}

/// A job's run assignment: version 2, an empty `service` and `job` set. The run id is
/// `<job>-job` (`job_run_id`); `read` refuses any other combination.
pub fn assigned_run(
    run: []const u8,
    job: []const u8,
    requests: Requests,
    reason: []const u8,
) Assigned {
    assert(std.mem.eql(u8, job_of_run(run) orelse "", job));
    return .{
        .v = assigned_version_job,
        .replica = run,
        .requests = requests,
        .reason = reason,
        .job = job,
    };
}

/// Whether the assignment is a job's run. A run's `service` is empty and no service has an empty
/// name, so the scheduler's per-service spread never counts a run toward a service.
pub fn assigned_is_job(assigned: *const Assigned) bool {
    return assigned.job != null;
}

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

/// The format version each record kind is written in: the default of its `v` member, the one
/// place it is set. A reader accepts every version up to it.
pub fn version_current(comptime T: type) u32 {
    return std.meta.fieldInfo(T, .v).attrs.defaultValue(u32).?;
}

pub const SubjectKind = enum { service, replica, node, job };

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
    v: u32 = 3,
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
    /// A placement's locality (version 3): the bytes of the replica's tree the chosen node was
    /// estimated to hold, and the revision of the `/node-store/<node>` record that estimate read
    /// (0: the node had none). Absent on any other decision and on those written before C2.
    locality_bytes: ?u64 = null,
    node_store_revision: ?u64 = null,
    /// The revision the scheduler read the world at when it chose (version 3, placements only):
    /// the simulations' L1 judges the choice by what had not changed since.
    read_revision: ?u64 = null,
};

/// Decisions are written at the oldest version that holds their members: version 3 only when the
/// locality members are present, so a decision with none stays readable by a C1 build.
pub const decision_version_locality: u32 = 3;
pub const decision_version_plain: u32 = 2;

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

/// A run that encodes over `job_run_bytes_max` got past the API's checks: our defect (ZC-B0005),
/// not a capacity the operator can raise.
fn run_too_large(diag: *Diag, id: []const u8, bytes: usize) Error {
    diag.raise(.B0005);
    diag.cause("the run {s} encodes as {d} bytes, over the {d} bytes a run record may take", .{
        id, bytes, constants.job_run_bytes_max,
    });
    diag.fix(.{ .sentence = "report it with the diagnostic bundle; the job was not started" });
    return error.NoCapacity;
}

/// Encodes a record as compact JSON in `arena`.
pub fn encode(arena: Allocator, value: anytype, diag: *Diag) Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const options: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };
    std.json.Stringify.value(value, options, &out.writer) catch
        return failures.no_memory(diag);
    const bytes = out.toOwnedSlice() catch return failures.no_memory(diag);
    assert(bytes.len > 0);
    if (bytes.len > constants.store_value_bytes_max) {
        return failures.value_too_large(diag, bytes.len);
    }
    // The API checks a job's words against its bounds, but escaping can multiply bytes (a control
    // character is six): the encoded run is what the agents' runs reply is sized by.
    const T = @TypeOf(value);
    if (T == JobRun and bytes.len > constants.job_run_bytes_max) {
        return run_too_large(diag, value.id, bytes.len);
    }
    return bytes;
}

/// Parses the value of `kv` as a `T`. A value that is not one is ZC-E0301 naming the key.
pub fn read(comptime T: type, arena: Allocator, kv: store.KeyValue, diag: *Diag) Error!T {
    assert(kv.key.len > 0);
    // The agent endpoint refuses a larger pull record; a row that holds one was not written
    // through it, and parsing it would cost the arena several times its size.
    if (T == Pull and kv.value.len > constants.pull_record_bytes_max) {
        return malformed(diag, kv.key, @typeName(T));
    }
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    if (@hasField(T, "v")) {
        // The version comes before the shape: a newer release may have changed the shape.
        const Head = struct { v: ?u32 = null };
        const head = std.json.parseFromSliceLeaky(Head, arena, kv.value, options) catch |err| {
            if (err == error.OutOfMemory) return failures.no_memory(diag);
            return malformed(diag, kv.key, @typeName(T));
        };
        const known = version_current(T);
        if ((head.v orelse 0) > known) return too_new(diag, kv.key, head.v.?, known);
    }
    // The same bound `encode` enforces: the runs reply of a node adds up these records. After
    // the version: a newer release may have raised it.
    if (T == JobRun and kv.value.len > constants.job_run_bytes_max) {
        return malformed(diag, kv.key, @typeName(T));
    }
    const record = std.json.parseFromSliceLeaky(T, arena, kv.value, options) catch |err| {
        if (err == error.OutOfMemory) return failures.no_memory(diag);
        return malformed(diag, kv.key, @typeName(T));
    };
    // The agent endpoint refuses these; a row that holds one anyway was not written through it.
    if (T == Pull and !pull_peers_named(record)) return malformed(diag, kv.key, @typeName(T));
    if (T == Job or T == JobRun) {
        if (!job_valid(record)) return malformed(diag, kv.key, @typeName(T));
    }
    if (T == Assigned and !assigned_valid(record)) return malformed(diag, kv.key, @typeName(T));
    if (T == Observed and !observed_valid(&record)) return malformed(diag, kv.key, @typeName(T));
    if (T == JobStatus and !record.valid()) return malformed(diag, kv.key, @typeName(T));
    if (T == JobObserved and !record.valid()) return malformed(diag, kv.key, @typeName(T));
    if (T == JobAdmission and !admission_valid(record)) {
        return malformed(diag, kv.key, @typeName(T));
    }
    return record;
}

/// Whether a pull record names at most `pull_peers_max` peers in each list and every one is a
/// node name.
fn pull_peers_named(record: Pull) bool {
    if (record.peer_bytes.len > constants.pull_peers_max) return false;
    if (record.bad_peers.len > constants.pull_peers_max) return false;
    for (record.peer_bytes) |sent| {
        if (name_problem(sent.peer, constants.node_name_bytes_max) != null) return false;
    }
    for (record.bad_peers) |named| {
        if (name_problem(named, constants.node_name_bytes_max) != null) return false;
    }
    return true;
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
        .refused => std.fmt.bufPrint(buffer, "was refused by the node's trust policy", .{}),
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
        .v = assigned_version_plain,
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

test "observed and decision write their versions with their new members, and read them back" {
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

    // `refused` is a job's exit kind only (B5): a replica's record that holds it is malformed.
    var refused = observed;
    refused.status = .stopped;
    refused.exit = .{ .kind = .refused };
    const refused_kv = kv_of("/observed/node1/hello-1", try encode(arena, refused, &diag));
    try testing.expectError(error.Malformed, read(Observed, arena, refused_kv, &diag));
    diag.reset();

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
    try testing.expect(std.mem.startsWith(u8, decision_bytes, "{\"v\":3,"));
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
            try testing.expectEqualStrings("", record.source);
            seen[0] += 1;
        } else if (std.mem.startsWith(u8, kv.key, prefix_replicas)) {
            const record = try read(Replica, arena, kv, &diag);
            try testing.expectEqual(@as(u32, 1), record.v);
            try testing.expectEqualStrings("", record.source);
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

/// Records captured from a real C1 server and agent, the same way (src/testdata/README.md).
const c1_store = @embedFile("testdata/c1_store.txt");

test "records a C1 build wrote still read" {
    // Goal: a stored value is read by the next release. Method: read every record of a store a C1
    // build produced (services with env and limits, a replaced replica, a held one) as the type
    // its key says; services and replicas are version 2 with no `source`, observed and decisions
    // are version 2 too.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    var seen: [5]u32 = @splat(0);
    var lines = std.mem.splitScalar(u8, c1_store, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t').?;
        const kv = kv_of(line[0..tab], line[tab + 1 ..]);
        if (std.mem.startsWith(u8, kv.key, prefix_services)) {
            const record = try read(Service, arena, kv, &diag);
            try testing.expectEqual(@as(u32, 2), record.v);
            try testing.expectEqualStrings("", record.source);
            seen[0] += 1;
        } else if (std.mem.startsWith(u8, kv.key, prefix_replicas)) {
            const record = try read(Replica, arena, kv, &diag);
            try testing.expectEqual(@as(u32, 2), record.v);
            try testing.expectEqualStrings("", record.source);
            seen[1] += 1;
        } else if (std.mem.startsWith(u8, kv.key, prefix_observed)) {
            const record = try read(Observed, arena, kv, &diag);
            try testing.expectEqual(@as(u32, 2), record.v);
            seen[2] += 1;
        } else if (std.mem.startsWith(u8, kv.key, prefix_decisions)) {
            const record = try read(Decision, arena, kv, &diag);
            try testing.expectEqual(@as(u32, 2), record.v);
            seen[3] += 1;
        } else if (std.mem.startsWith(u8, kv.key, prefix_nodes)) {
            _ = try read(Node, arena, kv, &diag);
            seen[4] += 1;
        }
    }
    for (seen) |count| try testing.expect(count > 0);
}

/// `/pulls/` rows captured from a real swarm-smoke run (src/testdata/README.md).
const c2_pulls = @embedFile("testdata/c2_pulls.txt");

test "a pull record naming a peer that is not a node name does not read" {
    // Goal: the read side of the agent endpoint's name check. Method: a row stored with a bad
    // name in `peer_bytes`, one in `bad_peers`, and a good row; only the good one reads.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    const head = "{\"v\":1,\"node\":\"node1\",\"tree\":\"b3:1\",";
    const bad_sent = head ++ "\"peer_bytes\":[{\"peer\":\"a b\",\"bytes\":1}]}";
    const bad_struck = head ++ "\"bad_peers\":[\"<script>\"]}";
    const good = head ++
        "\"peer_bytes\":[{\"peer\":\"node2\",\"bytes\":1}],\"bad_peers\":[\"node3\"]}";
    const key = "/pulls/node1/b3:1";
    try testing.expectError(error.Malformed, read(Pull, arena, kv_of(key, bad_sent), &diag));
    try testing.expect(diag.code == .E0301);
    diag.reset();
    try testing.expectError(error.Malformed, read(Pull, arena, kv_of(key, bad_struck), &diag));
    diag.reset();
    const record = try read(Pull, arena, kv_of(key, good), &diag);
    try testing.expectEqualStrings("node2", record.peer_bytes[0].peer);
}

test "a pull record over the size bound or naming too many peers does not read" {
    // Goal: the read side of the agent endpoint's size and peer-count checks. Method: a valid row
    // padded past `pull_record_bytes_max` (before parsing), one with `pull_peers_max` + 1 peers,
    // and the same row at the bounds, which reads.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    const key = "/pulls/node1/b3:1";
    const head = "{\"v\":1,\"node\":\"node1\",\"tree\":\"b3:1\",\"bad_peers\":[";
    var rows: [3][]const u8 = undefined;
    var at: usize = 0;
    var many: std.ArrayList(u8) = .empty;
    try many.appendSlice(arena, head);
    for (0..constants.pull_peers_max + 1) |index| {
        if (index > 0) try many.append(arena, ',');
        try many.appendSlice(arena, "\"node2\"");
        if (index == constants.pull_peers_max - 1) {
            try many.appendSlice(arena, "]}");
            rows[at] = try arena.dupe(u8, many.items); // Exactly the bound: reads.
            at += 1;
            many.shrinkRetainingCapacity(many.items.len - 2);
            try many.append(arena, ',');
        }
    }
    try many.appendSlice(arena, "]}");
    rows[at] = many.items; // One past the bound.
    const padded = try arena.alloc(u8, constants.pull_record_bytes_max + 1);
    @memset(padded, ' ');
    @memcpy(padded[0..rows[0].len], rows[0]); // A valid record followed by spaces: too long.
    _ = try read(Pull, arena, kv_of(key, rows[0]), &diag);
    try testing.expectError(error.Malformed, read(Pull, arena, kv_of(key, rows[1]), &diag));
    diag.reset();
    try testing.expectError(error.Malformed, read(Pull, arena, kv_of(key, padded), &diag));
    try testing.expect(diag.code == .E0301);
}

test "pull records a real run wrote still read" {
    // Goal: Pull v1 as stored reads under its own key. Method: read each captured row as a `Pull`,
    // check the key is the one its node and tree give, and check the bytes by source.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    var rows: u32 = 0;
    var struck: u32 = 0;
    var lines = std.mem.splitScalar(u8, c2_pulls, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t').?;
        const kv = kv_of(line[0..tab], line[tab + 1 ..]);
        const record = try read(Pull, arena, kv, &diag);
        try testing.expectEqual(@as(u32, 1), record.v);
        try testing.expectEqualStrings(pull_key(record.node, record.tree).slice(), kv.key);
        try testing.expectEqual(@as(u64, 1353576), record.registry_bytes + sum_peers(record));
        try testing.expect(record.finished_at_ms >= record.started_at_ms);
        struck += @intCast(record.bad_peers.len);
        rows += 1;
    }
    try testing.expectEqual(@as(u32, 3), rows);
    try testing.expectEqual(@as(u32, 1), struck);
}

fn sum_peers(record: Pull) u64 {
    var total: u64 = 0;
    for (record.peer_bytes) |peer| total += peer.bytes;
    return total;
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

test "source round-trips at version 3 and a version 4 service is refused" {
    // Goal: `source` is stored and read back, absent means empty, and a newer service is named.
    // Method: encode a service with and without it, read both back, then read a v4 value.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    const reference = "registry.example/hello@sha256:" ++
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const base: Service = .{
        .name = "hello",
        .image = "b3:51aa9c03",
        .replicas = 1,
        .command = &.{"run"},
        .generation = 1,
    };
    var with = base;
    with.source = reference;
    const with_bytes = try encode(arena, with, &diag);
    const with_back = try read(Service, arena, kv_of("/services/hello", with_bytes), &diag);
    try testing.expectEqual(@as(u32, 3), with_back.v);
    try testing.expectEqualStrings(reference, with_back.source);
    const without_bytes = try encode(arena, base, &diag);
    const without_back = try read(Service, arena, kv_of("/services/hello", without_bytes), &diag);
    try testing.expectEqualStrings("", without_back.source);
    const replica: Replica = .{
        .id = "hello-1",
        .service = "hello",
        .generation = 1,
        .image = "b3:51aa9c03",
        .command = &.{"run"},
        .source = reference,
    };
    const replica_bytes = try encode(arena, replica, &diag);
    const replica_kv = kv_of("/replicas/hello/hello-1", replica_bytes);
    const replica_back = try read(Replica, arena, replica_kv, &diag);
    try testing.expectEqualStrings(reference, replica_back.source);
    const newer = "{\"v\":4,\"name\":\"hello\"}";
    const newer_kv = kv_of("/services/hello", newer);
    try testing.expectError(error.Malformed, read(Service, arena, newer_kv, &diag));
    try testing.expectEqual(codes.Code.E0303, diag.code.?);
    try testing.expectEqualStrings(
        "the value at /services/hello is version 4; this release reads up to version 3",
        diag.last_cause().?,
    );
}

test "a newer version is refused before the shape is parsed" {
    // Goal: E0303, not E0301, for a too-new value whose shape this release cannot parse.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diag: Diag = undefined;
    diag.reset();
    const kv = kv_of("/nodes/n", "{\"v\":9,\"name\":7,\"capacity\":\"big\"}");
    try testing.expectError(error.Malformed, read(Node, arena_state.allocator(), kv, &diag));
    try testing.expectEqual(codes.Code.E0303, diag.code.?);
    try testing.expectEqualStrings(
        "the value at /nodes/n is version 9; this release reads up to version 1",
        diag.last_cause().?,
    );
}

test "the version a record is written in is the version the reader accepts" {
    // Goal: one source for the version. Method: for every versioned record, a value at the
    // version it is written in encodes with that `v` and reads back, and one more is refused.
    // (`std.mem.zeroes` zeroes `v` too, so it is set to the default it would otherwise take.)
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    inline for (.{
        Service,       Replica,    Node,
        Observed,      Assigned,   Allocation,
        Audit,         NodeStatus, Summary,
        ReplicaNumber, Decision,   IndexEntry,
        NodeStore,     Pull,       JobInput,
        JobAdmission,  JobEndings, JobStatus,
        JobObserved,
    }) |T| {
        var value = std.mem.zeroes(T);
        value.v = version_current(T);
        // A replica's assignment: `read` refuses one with neither a service nor a job.
        if (T == Assigned) value.service = "s";
        const bytes = try encode(arena, value, &diag);
        const prefix = try std.fmt.allocPrint(arena, "{{\"v\":{d},", .{version_current(T)});
        try testing.expect(std.mem.startsWith(u8, bytes, prefix));
        _ = try read(T, arena, kv_of("/k", bytes), &diag);
        const newer = try std.fmt.allocPrint(arena, "{{\"v\":{d}}}", .{version_current(T) + 1});
        diag.reset();
        try testing.expectError(error.Malformed, read(T, arena, kv_of("/k", newer), &diag));
        try testing.expectEqual(codes.Code.E0303, diag.code.?);
        diag.reset();
    }
}

test "the keys of B1 follow docs/keys.md" {
    // Goal: one implementation of the job layout. Method: build each and compare.
    try testing.expectEqualStrings("/jobs/job1", job_key("job1").slice());
    try testing.expectEqualStrings("/job-input/job1", job_input_key("job1").slice());
    try testing.expectEqualStrings("/job-runs/job1", job_run_key("job1").slice());
    try testing.expectEqualStrings("/job-status/job1", job_status_key("job1").slice());
    try testing.expectEqualStrings("/job-observed/n1/", job_observed_prefix("n1").slice());
    try testing.expectEqualStrings("/job-observed/n1/job1", job_observed_key("n1", "job1").slice());
    try testing.expectEqualStrings("/job-admission", key_job_admission);
    try testing.expectEqualStrings("/job-endings", key_job_endings);
    var buffer: [constants.job_run_id_bytes_max]u8 = undefined;
    const id = job_run_id(&buffer, "job1");
    try testing.expectEqualStrings("job1-job", id);
    try testing.expectEqualStrings("job1", job_of_run(id).?);
    try testing.expect(job_of_run("hello-1") == null);
    try testing.expect(job_of_run("-job") == null);
    // A run id is never a replica id of any service, and is a container name.
    try testing.expect(replica_number("job1", id) == null);
    try testing.expect(replica_number("job1-job", id) == null);
    const longest: [constants.service_name_bytes_max]u8 = @splat('j');
    const long_id = job_run_id(&buffer, &longest);
    try testing.expect(long_id.len <= constants.node_name_bytes_max);
    try testing.expect(job_observed_key(&longest, &longest).len <= constants.store_key_bytes_max);
}

test "job records encode, read back, and keep the invariants of their members" {
    // Goal: the job records round-trip, and a row the API could not have written is malformed.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    const job: Job = .{
        .name = "j",
        .image = "sha256:aa",
        .command = &.{ "run", "--x" },
        .deadline_ms = 1000,
        .input_env = "INPUT",
        .input_digest = "sha256:bb",
        .input_bytes = 9,
        .submit_by_ms = 5,
        .created_at_ms = 1,
        .cancel_requested = .{ .at_ms = 4, .by = "me" },
    };
    const bytes = try encode(arena, job, &diag);
    try testing.expect(std.mem.startsWith(u8, bytes, "{\"v\":1,"));
    const back = try read(Job, arena, kv_of("/jobs/j", bytes), &diag);
    try testing.expectEqual(@as(u64, 4), back.cancel_requested.?.at_ms);
    try testing.expectEqual(@as(u32, 0), back.retries);
    try job_without_command_is_malformed(arena, &diag);
}

fn job_without_command_is_malformed(arena: Allocator, diag: *Diag) !void {
    const no_command = try encode(arena, Job{
        .name = "j",
        .image = "i",
        .command = &.{},
        .deadline_ms = 1,
        .submit_by_ms = 1,
        .created_at_ms = 1,
    }, diag);
    try testing.expectError(error.Malformed, read(Job, arena, kv_of("/jobs/j", no_command), diag));
    diag.reset();
}

test "a job status must say how it ended exactly when it has ended" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();

    const ended: JobStatus = .{
        .state = .exited,
        .end = .{ .kind = .exited, .code = 3 },
        .ended_at_ms = 9,
        .reported_at_ms = 9,
    };
    const status_bytes = try encode(arena, ended, &diag);
    _ = try read(JobStatus, arena, kv_of("/job-status/j", status_bytes), &diag);
    const bad = [_]JobStatus{
        .{ .state = .running, .reported_at_ms = 1, .end = .{ .kind = .cancelled } },
        .{ .state = .exited, .reported_at_ms = 1 },
        .{ .state = .exited, .reported_at_ms = 1, .ended_at_ms = 1, .end = .{ .kind = .failed } },
        .{ .state = .exited, .reported_at_ms = 1, .ended_at_ms = 1, .end = .{
            .kind = .exited,
            .code = 1,
            .signal = 9,
        } },
        .{ .state = .failed, .reported_at_ms = 1, .ended_at_ms = 1, .end = .{ .kind = .failed } },
    };
    for (bad) |status| {
        const text = try encode(arena, status, &diag);
        try testing.expectError(
            error.Malformed,
            read(JobStatus, arena, kv_of("/job-status/j", text), &diag),
        );
        diag.reset();
    }
    const cause = try encode(arena, JobStatus{
        .state = .failed,
        .reported_at_ms = 1,
        .ended_at_ms = 1,
        .end = .{ .kind = .failed, .cause = .@"unreachable" },
    }, &diag);
    try testing.expect(std.mem.indexOf(u8, cause, "\"cause\":\"unreachable\"") != null);
}

test "an admission record must add up" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    const good: JobAdmission = .{ .admitted = 5, .hours = &.{
        .{ .hour = 1, .count = 2 }, .{ .hour = 2, .count = 3 },
    } };
    const bytes = try encode(arena, good, &diag);
    _ = try read(JobAdmission, arena, kv_of(key_job_admission, bytes), &diag);
    const lies = [_]JobAdmission{
        .{ .admitted = 4, .hours = good.hours },
        .{ .admitted = 5, .hours = &.{ .{ .hour = 2, .count = 2 }, .{ .hour = 2, .count = 3 } } },
    };
    for (lies) |lie| {
        const text = try encode(arena, lie, &diag);
        try testing.expectError(
            error.Malformed,
            read(JobAdmission, arena, kv_of(key_job_admission, text), &diag),
        );
        diag.reset();
    }
}

test "assigned: a version 1 record reads, and a run's assignment names its job" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    const old = "{\"v\":1,\"replica\":\"h-1\",\"service\":\"h\"," ++
        "\"requests\":{\"cpu_millis\":1,\"memory_bytes\":2},\"reason\":\"r\"}";
    const back = try read(Assigned, arena, kv_of("/assigned/n/h-1", old), &diag);
    try testing.expect(back.job == null);
    try testing.expect(!assigned_is_job(&back));
    const run = assigned_run("j-job", "j", .{ .cpu_millis = 1, .memory_bytes = 2 }, "r");
    const bytes = try encode(arena, run, &diag);
    try testing.expect(std.mem.startsWith(u8, bytes, "{\"v\":2,"));
    const again = try read(Assigned, arena, kv_of("/assigned/n/j-job", bytes), &diag);
    try testing.expect(assigned_is_job(&again));
    try testing.expectEqual(assigned_version_job, version_current(Assigned));
}

test "assigned: a replica is written at version 1, and only a run at version 2" {
    // Goal: the mixed-version rule of the brief (Assigned v2). Method: what a reader of the
    // previous release (version 1, no `job`) does with what this release writes.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    const requests: Requests = .{ .cpu_millis = 1, .memory_bytes = 2 };
    const replica = assigned_replica("h-1", "h", requests, "r");
    const replica_bytes = try encode(arena, replica, &diag);
    try testing.expect(std.mem.startsWith(u8, replica_bytes, "{\"v\":1,"));
    // The previous release's record: version 1, no job. It reads the replica's record as it did.
    const Previous = struct {
        v: u32 = 1,
        replica: []const u8,
        service: []const u8,
        requests: Requests,
        reason: []const u8,
    };
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    const old = try std.json.parseFromSliceLeaky(Previous, arena, replica_bytes, options);
    try testing.expect(old.v <= 1);
    try testing.expectEqualStrings("h", old.service);
    // A run is version 2, which that release refuses as too new (it does not misread it as a
    // replica of no service): the scheduler writes runs only once every agent is upgraded.
    const run_bytes = try encode(arena, assigned_run("j-job", "j", requests, "r"), &diag);
    const run_head = try std.json.parseFromSliceLeaky(struct { v: u32 }, arena, run_bytes, options);
    try testing.expect(run_head.v > 1);
    // This release reads both, and an old v1 text as it was written.
    const back = try read(Assigned, arena, kv_of("/assigned/n/h-1", replica_bytes), &diag);
    try testing.expect(back.job == null and back.v == 1);
}

test "assigned: a job is set exactly when the service is empty, and names its run" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    const requests: Requests = .{ .cpu_millis = 1, .memory_bytes = 2 };
    const bad = [_]Assigned{
        // A service and a job.
        .{ .replica = "j-job", .service = "s", .requests = requests, .reason = "r", .job = "j" },
        // Neither.
        .{ .v = 1, .replica = "s-1", .requests = requests, .reason = "r" },
        // A job at version 1.
        .{ .v = 1, .replica = "j-job", .requests = requests, .reason = "r", .job = "j" },
        // A run whose replica is not `<job>-job`.
        .{ .replica = "k-job", .requests = requests, .reason = "r", .job = "j" },
        .{ .replica = "j-1", .requests = requests, .reason = "r", .job = "j" },
    };
    for (bad) |record| {
        const text = try encode(arena, record, &diag);
        try testing.expectError(
            error.Malformed,
            read(Assigned, arena, kv_of("/assigned/n/x", text), &diag),
        );
        diag.reset();
    }
}

test "a run record over job_run_bytes_max is refused at write and at read" {
    // Goal: the runs reply rests on an enforced bound. Method: an env of 8 KiB of control
    // characters is within job_env_bytes_max raw and six times that once JSON-escaped.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    const control: [constants.job_env_bytes_max - 8]u8 = @splat(1);
    var run: JobRun = .{
        .id = "j-job",
        .job = "j",
        .image = "i",
        .command = &.{"x"},
        .deadline_ms = 1,
        .start_by_ms = 2,
        .created_at_ms = 1,
        .env = &.{.{ "K", &control }},
    };
    try testing.expectError(error.NoCapacity, encode(arena, run, &diag));
    try testing.expectEqual(codes.Code.B0005, diag.code.?);
    diag.reset();
    run.env = &.{.{ "K", "plain" }};
    const bytes = try encode(arena, run, &diag);
    _ = try read(JobRun, arena, kv_of("/job-runs/j", bytes), &diag);
    // A row that is over the bound anyway (not written through `encode`) is malformed.
    const pad: [constants.job_run_bytes_max]u8 = @splat('p');
    const padded = try std.fmt.allocPrint(arena, "{s},\"pad\":\"{s}\"}}", .{
        bytes[0 .. bytes.len - 1],
        &pad,
    });
    const over = read(JobRun, arena, kv_of("/job-runs/j", padded), &diag);
    try testing.expectError(error.Malformed, over);
    // A newer, larger record is too new (ZC-E0303), not malformed: the version comes first.
    diag.reset();
    const newer = try std.fmt.allocPrint(arena, "{{\"v\":99,\"pad\":\"{s}\"}}", .{&pad});
    const too_new_read = read(JobRun, arena, kv_of("/job-runs/j", newer), &diag);
    try testing.expectError(error.Malformed, too_new_read);
    try testing.expectEqual(codes.Code.E0303, diag.code.?);
}

test "a job observation says how the run ended exactly when it stopped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    const base: JobObserved = .{
        .run = "j-job",
        .node = "n1",
        .tenure = 1,
        .assignment = 2,
        .status = .claimed,
        .reported_at_ms = 3,
    };
    var running = base;
    running.status = .running;
    running.started_at_ms = 4;
    var stopped = running;
    stopped.status = .stopped;
    stopped.exit = .{ .kind = .exited, .code = 0 };
    for ([_]JobObserved{ base, running, stopped }) |good| {
        const text = try encode(arena, good, &diag);
        _ = try read(JobObserved, arena, kv_of("/job-observed/n1/j", text), &diag);
    }
    var no_exit = stopped;
    no_exit.exit = null;
    var early_exit = running;
    early_exit.exit = .{ .kind = .exited, .code = 0 };
    var claimed_started = base;
    claimed_started.started_at_ms = 4;
    for ([_]JobObserved{ no_exit, early_exit, claimed_started }) |bad| {
        const text = try encode(arena, bad, &diag);
        try testing.expectError(
            error.Malformed,
            read(JobObserved, arena, kv_of("/job-observed/n1/j", text), &diag),
        );
        diag.reset();
    }
}

test "a value over store_value_bytes_max says it is the value, not the request's memory" {
    // Goal: RA-N4. Both are ZC-E0207, but the cause of an oversized record must name its size and
    // the bound, never "the memory set aside for this request ran out".
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    const text: [constants.store_value_bytes_max]u8 = @splat('a');
    try testing.expectError(error.NoCapacity, encode(arena, JobInput{ .base64 = &text }, &diag));
    try testing.expectEqual(codes.Code.E0207, diag.code.?);
    const cause = diag.last_cause().?;
    try testing.expect(std.mem.indexOf(u8, cause, "one value") != null);
    try testing.expect(std.mem.indexOf(u8, cause, "memory") == null);
}
