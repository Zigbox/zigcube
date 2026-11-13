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
pub const prefix_history = "/history/";
pub const prefix_rollouts = "/rollouts/";
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

/// `/history/<service>/<generation>`, the generation in decimal without padding: a reader sorts
/// by the number, never by the key (docs/keys.md).
pub fn history_key(service: []const u8, generation: u64) Key {
    assert(name_problem(service, constants.service_name_bytes_max) == null);
    assert(generation > 0);
    var digits: [20]u8 = undefined;
    const text = std.fmt.bufPrint(&digits, "{d}", .{generation}) catch unreachable; // 20 digits.
    return Key.build(&.{ prefix_history, service, "/", text });
}

pub fn history_prefix(service: []const u8) Key {
    assert(name_problem(service, constants.service_name_bytes_max) == null);
    return Key.build(&.{ prefix_history, service, "/" });
}

/// The generation a history key names, or null when the last part is not a generation.
pub fn history_generation(key: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, key, prefix_history)) return null;
    const slash = std.mem.lastIndexOfScalar(u8, key, '/') orelse return null;
    const text = key[slash + 1 ..];
    if (text.len == 0 or text[0] == '0') return null;
    const generation = std.fmt.parseInt(u64, text, 10) catch return null;
    return generation;
}

pub fn rollout_key(service: []const u8) Key {
    assert(name_problem(service, constants.service_name_bytes_max) == null);
    return Key.build(&.{ prefix_rollouts, service });
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
pub const JobRelay = struct { name: []const u8, address: []const u8 };

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

/// A service's health check (C3): a command run inside the container, exit 0 healthy. Every member
/// is written; `apply` refuses a check that cannot be met (ZC-E0125).
pub const Health = struct {
    command: []const []const u8,
    interval_ms: u32,
    timeout_ms: u32,
    start_period_ms: u32 = 0,
    failure_threshold: u32,
    success_threshold: u32,

    pub fn equal(first: Health, second: Health) bool {
        if (!strings_equal(first.command, second.command)) return false;
        if (first.interval_ms != second.interval_ms) return false;
        if (first.timeout_ms != second.timeout_ms) return false;
        if (first.start_period_ms != second.start_period_ms) return false;
        if (first.failure_threshold != second.failure_threshold) return false;
        return first.success_threshold == second.success_threshold;
    }
};

pub fn health_equal(first: ?Health, second: ?Health) bool {
    const left = first orelse return second == null;
    const right = second orelse return false;
    return left.equal(right);
}

pub const RolloutStrategy = enum { rolling, recreate };
pub const RolloutOnFailure = enum { rollback, pause };

/// How a new generation replaces the old (C3). The defaults are every service's rollout
/// (docs/decisions/2026-11-05-c3-owner-answers.md, answer 4); a service that holds no `rollout`
/// has exactly these.
pub const RolloutPolicy = struct {
    strategy: RolloutStrategy = .rolling,
    max_surge: u32 = 1,
    max_unavailable: u32 = 0,
    min_ready_ms: u32 = 5_000,
    ready_timeout_ms: u32 = 120_000,
    progress_deadline_ms: u32 = 600_000,
    grace_ms: u32 = 10_000,
    on_failure: RolloutOnFailure = .rollback,

    pub fn equal(first: RolloutPolicy, second: RolloutPolicy) bool {
        return std.meta.eql(first, second);
    }
};

/// One grant on a destination service (C4): replicas of `from` may connect to `port` of this
/// service through the mesh (docs/keys.md, `/services`). `apply` refuses a bad one (ZC-E0135); a
/// record that holds one anyway does not read.
pub const Grant = struct {
    from: []const u8,
    port: u32,

    pub fn equal(first: Grant, second: Grant) bool {
        return first.port == second.port and std.mem.eql(u8, first.from, second.from);
    }
};

pub fn grants_equal(first: []const Grant, second: []const Grant) bool {
    if (first.len != second.len) return false;
    for (first, second) |left, right| {
        if (!left.equal(right)) return false;
    }
    return true;
}

pub fn grants_contain(grants: []const Grant, grant: Grant) bool {
    for (grants) |held| {
        if (held.equal(grant)) return true;
    }
    return false;
}

pub const Service = struct {
    v: u32 = service_version_mesh,
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
    /// The health check (version 4); absent: none.
    health: ?Health = null,
    /// The rollout policy (version 4); absent: the default, `RolloutPolicy{}`. `apply` stores
    /// none when the policy is the default.
    rollout: ?RolloutPolicy = null,
    /// Version 5 (C4): the mesh address, `127.77.<hi>.<lo>`, given by the API from
    /// `/mesh-address-next` when the service is created and never changed while it exists
    /// (docs/keys.md). Absent in a record written before C4 until its next apply.
    mesh_address: ?[]const u8 = null,
    /// Version 5: who may connect to this service through the mesh, at most `service_allow_max`
    /// grants. Not part of what a replica runs: a change is never a new generation.
    allow: []const Grant = &.{},
    pub fn rollout_policy(service: *const Service) RolloutPolicy {
        return service.rollout orelse .{};
    }
};

/// Services and replicas are written at the oldest version that holds their members: version 4
/// only with a `health` or a `rollout`, so that a release before C3 still reads every service that
/// uses neither, and version 5 only with a `mesh_address` or an `allow` (docs/keys.md,
/// "Versions"). `encode` sets it, so no writer can leave `v` at the default. Replicas stop at 4:
/// the mesh members are not copied into them.
pub const service_version_plain: u32 = 3;
pub const service_version_rollout: u32 = 4;
pub const service_version_mesh: u32 = 5;

pub fn service_version(service: *const Service) u32 {
    if (service.mesh_address != null) return service_version_mesh;
    if (service.allow.len > 0) return service_version_mesh;
    if (service.health != null) return service_version_rollout;
    if (service.rollout != null) return service_version_rollout;
    return service_version_plain;
}

pub fn replica_version(replica: *const Replica) u32 {
    if (replica.health != null) return service_version_rollout;
    return service_version_plain;
}

// ---- Mesh addresses (C4) ------------------------------------------------------------------------

/// `/mesh-address-next`: the number the next mesh address takes, from `mesh_address_min`. Past
/// `mesh_address_max` it wraps, and the API then looks for an address no one holds
/// (docs/keys.md, "Mesh addresses").
pub const MeshAddressNext = struct {
    v: u32 = 1,
    next: u32,
};

/// `/mesh-addresses/<n>`: who holds address `n`. Written by the API with the service that takes
/// it; marked released when that service is deleted, and replaced only by the allocation that
/// reuses it, once the quarantine has passed and no replica of `service` remains.
pub const MeshAddressHold = struct {
    v: u32 = 1,
    service: []const u8,
    /// When the service was deleted; absent while it exists.
    released_at_ms: ?u64 = null,
};

pub const key_mesh_address_next = "/mesh-address-next";
pub const prefix_mesh_addresses = "/mesh-addresses/";

/// `/mesh-addresses/<n>`, `n` in five digits, so a listing is in address order.
pub fn mesh_address_key(number: u16) Key {
    assert(number >= constants.mesh_address_min);
    assert(number <= constants.mesh_address_max);
    var digits: [5]u8 = undefined;
    // Cannot fail: a u16 has at most five digits.
    const text = std.fmt.bufPrint(&digits, "{d:0>5}", .{number}) catch unreachable;
    return Key.build(&.{ prefix_mesh_addresses, text });
}

/// "127.77.<hi>.<lo>" for address number `number`.
pub fn mesh_address_text(
    buffer: *[constants.mesh_address_text_bytes_max]u8,
    number: u16,
) []const u8 {
    assert(number >= constants.mesh_address_min);
    assert(number <= constants.mesh_address_max);
    const first = constants.mesh_block_first_octet;
    const second = constants.mesh_block_second_octet;
    // Cannot fail: four octets of at most three digits and three dots fill at most 15 bytes,
    // and the first two are "127.77.", so the text is at most 13.
    return std.fmt.bufPrint(buffer, "{d}.{d}.{d}.{d}", .{
        first, second, number >> 8, number & 0xff,
    }) catch unreachable;
}

/// The number of a mesh address in its one canonical text, or null for anything else (another
/// block, a leading zero, the block's first or last address).
pub fn mesh_address_parse(text: []const u8) ?u16 {
    if (text.len > constants.mesh_address_text_bytes_max) return null;
    var parts = std.mem.splitScalar(u8, text, '.');
    var octets: [4]u8 = undefined;
    for (&octets) |*octet| {
        const part = parts.next() orelse return null;
        if (part.len == 0 or part.len > 3) return null;
        if (part.len > 1 and part[0] == '0') return null;
        octet.* = std.fmt.parseInt(u8, part, 10) catch return null;
    }
    if (parts.next() != null) return null;
    if (octets[0] != constants.mesh_block_first_octet) return null;
    if (octets[1] != constants.mesh_block_second_octet) return null;
    const number = @as(u16, octets[2]) << 8 | octets[3];
    if (number < constants.mesh_address_min) return null;
    if (number > constants.mesh_address_max) return null;
    return number;
}

/// Why an `.allow` list cannot be stored, as a cause sentence (ZC-E0135), or null if it can: a
/// port of 0 or above 65535, a source that is not a service name or is the service itself, the
/// same grant twice, more than `service_allow_max` grants.
pub fn allow_problem(
    buffer: []u8,
    service: []const u8,
    allow: []const Grant,
) ?[]const u8 {
    assert(buffer.len >= 128);
    if (allow.len > constants.service_allow_max) {
        return bufprint_cut(buffer, "it holds {d} grants; a service holds at most {d}", .{
            allow.len, constants.service_allow_max,
        });
    }
    for (allow, 0..) |grant, index| {
        const number = index + 1; // Counted from 1, as a person reads the list.
        if (name_problem(grant.from, constants.service_name_bytes_max) != null) {
            return bufprint_cut(buffer, "grant {d}: from is not a valid service name", .{number});
        }
        if (grant.port == 0 or grant.port > std.math.maxInt(u16)) {
            return bufprint_cut(buffer, "grant {d}: port {d} is not a port from 1 to 65535", .{
                number, grant.port,
            });
        }
        if (std.mem.eql(u8, grant.from, service)) {
            return bufprint_cut(buffer, "grant {d}: {s} names itself; a service does not " ++
                "reach itself through the mesh", .{ number, service });
        }
        if (grants_contain(allow[0..index], grant)) {
            return bufprint_cut(buffer, "grant {d}: {s} on port {d} is listed twice", .{
                number, grant.from, grant.port,
            });
        }
    }
    return null;
}

fn bufprint_cut(buffer: []u8, comptime format: []const u8, args: anytype) []const u8 {
    assert(buffer.len >= 128);
    // Cannot fail: every sentence of `allow_problem` names at most one valid service name
    // (`service_name_bytes_max`, 48 bytes) and two numbers, under the 128 bytes asserted.
    return std.fmt.bufPrint(buffer, format, args) catch unreachable;
}

/// Whether a service record's version 5 members are ones `apply` could have written.
fn service_mesh_valid(service: Service) bool {
    if (service.mesh_address) |text| {
        if (mesh_address_parse(text) == null) return false;
    }
    if (name_problem(service.name, constants.service_name_bytes_max) != null) return false;
    var buffer: [256]u8 = undefined;
    return allow_problem(&buffer, service.name, service.allow) == null;
}

/// The counter that keeps replica ids unique forever: the number the next replica takes.
pub const ReplicaNumber = struct {
    v: u32 = 1,
    next: u64,
};

/// What a service asks for, once per replica. Where it runs is `/assigned`'s (the scheduler's);
/// a v1 record's `node` and `requests` are ignored on read.
pub const Replica = struct {
    v: u32 = service_version_rollout,
    id: []const u8,
    service: []const u8,
    generation: u64,
    image: []const u8,
    command: []const []const u8,
    env: []const Pair = &.{},
    limits: Limits = .{},
    /// The service's `source`, copied (absent before version 3).
    source: []const u8 = "",
    /// The service's `health`, copied (version 4): the agent runs the check.
    health: ?Health = null,
};

/// Why a generation was applied (`/history`).
pub const HistoryReason = enum { apply, rollback, auto_rollback };

/// `/history/<service>/<generation>`: what one generation of a service ran, as the service record
/// held it when that generation was applied. Written by the API in the apply's transaction, never
/// changed; at most `history_generations_max` per service (docs/keys.md).
pub const History = struct {
    v: u32 = 1,
    service: []const u8,
    generation: u64,
    image: []const u8,
    source: []const u8 = "",
    command: []const []const u8,
    env: []const Pair = &.{},
    limits: Limits = .{},
    health: ?Health = null,
    applied_by: []const u8,
    request_id: []const u8,
    applied_at_ms: u64,
    reason: HistoryReason,
    /// The generation whose spec a rollback copied; absent for `apply`.
    restores: ?u64 = null,
};

/// The history record of what `service` runs now, at its generation.
pub fn history_of(service: *const Service, applied_at_ms: u64) History {
    assert(service.generation > 0);
    return .{
        .service = service.name,
        .generation = service.generation,
        .image = service.image,
        .source = service.source,
        .command = service.command,
        .env = service.env,
        .limits = service.limits,
        .health = service.health,
        .applied_by = service.applied_by,
        .request_id = service.request_id,
        .applied_at_ms = applied_at_ms,
        .reason = .apply,
    };
}

pub const RolloutPhase = enum { progressing, paused, rolling_back, complete, failed };

/// What the replica controller may do now for a rollout: start this many new replicas, retire
/// this many old ones.
pub const RolloutBudget = struct {
    start: u32 = 0,
    retire: u32 = 0,
};

/// `/rollouts/<service>`: the one rollout of a service, written by the rollout controller (C3
/// slice 7). Defined here so that its key, writer and version are fixed first.
pub const Rollout = struct {
    v: u32 = 1,
    service: []const u8,
    /// The `create_revision` of the service key the rollout was started for. A service deleted
    /// and applied again is another service (its generations restart at 1): a rollout of the old
    /// one is not its rollout (`rollout_of`).
    service_created: u64,
    from: u64,
    to: u64,
    phase: RolloutPhase,
    started_at_ms: u64,
    deadline_at_ms: u64,
    /// When the controller next looks without a store change (`min_ready_ms` timers).
    next_at_ms: ?u64 = null,
    ready_new: u32 = 0,
    retired_old: u32 = 0,
    budget: RolloutBudget = .{},
    /// The decision that started or last moved the rollout.
    cause_decision: []const u8 = "",
};

/// Whether `rollout` is the rollout of the service whose key was created at
/// `service_create_revision` (null: no service). The API leaves `/rollouts/` alone when it deletes
/// a service (authority.md: the rollout controller is the prefix's one writer), so a rollout left
/// from a deleted service, or from one deleted and applied again, is not this service's: every
/// reader treats it as absent and the rollout controller deletes it.
pub fn rollout_of(rollout: *const Rollout, service_create_revision: ?u64) bool {
    const created = service_create_revision orelse return false;
    assert(created > 0);
    return rollout.service_created == created;
}

/// Whether `replica` runs what `service` asks for now: the image, `source`, command, `env`,
/// `limits` and `health`, the inputs that bump a service's `generation`. The generation alone
/// cannot say: it restarts at 1 when a service is deleted and applied again, so a replica of the
/// previous incarnation can be ahead of the new service, or equal to it, and still run something
/// else.
pub fn replica_runs_service(replica: *const Replica, service: *const Service) bool {
    if (!health_equal(replica.health, service.health)) return false;
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
};

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

/// What the agent's health check last said of a replica (`Observed` version 3).
pub const HealthState = enum { unknown, healthy, unhealthy };

pub const Observed = struct {
    v: u32 = observed_version_mesh,
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
    /// Version 3: the health check's verdict, absent for a replica without one.
    health: ?HealthState = null,
    /// Version 3: consecutive failed probes since the last success.
    health_failures: ?u32 = null,
    /// Version 3: the exit code of the last probe that ran to an exit, 0 to 255 like every exit
    /// code (`Exit`): a value outside it does not parse.
    last_probe_exit: ?u8 = null,
    /// Version 4 (C4): where the replica's supervisor takes mesh connections,
    /// `<node address>:<port>`, the node address being the one the agent advertises for C2's
    /// chunk server. Absent for a replica with no mesh port.
    endpoint: ?[]const u8 = null,
};

/// Observations are written at the oldest version that holds their members: version 3 only with
/// health, so a C1 or C2 server reads what an agent of this release reports for a replica without
/// a health check (docs/keys.md, `/observed`).
pub const observed_version_plain: u32 = 2;
pub const observed_version_health: u32 = 3;
pub const observed_version_mesh: u32 = 4;

pub fn observed_version(observed: *const Observed) u32 {
    if (observed.endpoint != null) return observed_version_mesh;
    const health = observed.health != null or observed.health_failures != null or
        observed.last_probe_exit != null;
    return if (health) observed_version_health else observed_version_plain;
}

/// Whether an observation's endpoint is `<host>:<port>` within `mesh_endpoint_bytes_max`, the
/// port from 1 to 65535. The host is the agent's to name; a reader does not resolve it.
pub fn endpoint_valid(endpoint: ?[]const u8) bool {
    const text = endpoint orelse return true;
    if (text.len > constants.mesh_endpoint_bytes_max) return false;
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return false;
    if (colon == 0) return false;
    for (text[0..colon]) |byte| {
        // A host name, IPv4, or bracketed IPv6 (whose colons are inside the brackets).
        const host_byte = std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '-' or
            byte == ':' or byte == '[' or byte == ']';
        if (!host_byte) return false;
    }
    const digits = text[colon + 1 ..];
    if (digits.len == 0 or digits.len > 5) return false;
    for (digits) |byte| if (!std.ascii.isDigit(byte)) return false;
    const port = std.fmt.parseInt(u32, digits, 10) catch unreachable; // At most five digits.
    return port > 0 and port <= std.math.maxInt(u16);
}

/// The health verdict an observation carries: `unknown` for one without a check, and for every
/// version 1 and 2 record, which predate health checks.
pub fn observed_health(observed: *const Observed) HealthState {
    if (observed.v < observed_version_health) return .unknown;
    return observed.health orelse .unknown;
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
    std.json.Stringify.value(at_oldest_version(value), options, &out.writer) catch
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

/// A service, replica or observation with `v` set to the oldest version that holds its members;
/// anything else as it is. The writer owns `v`, not whoever built the value: an agent's report
/// is parsed into an `Observed` (the endpoint refuses a member it does not know, ZC-E0104) and
/// stored at the version its members need, whatever `v` it named.
fn at_oldest_version(value: anytype) @TypeOf(value) {
    const T = @TypeOf(value);
    var written = value;
    if (T == Service) written.v = service_version(&value);
    if (T == Replica) written.v = replica_version(&value);
    if (T == Observed) written.v = observed_version(&value);
    return written;
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
    if (T == Service and !service_mesh_valid(record)) return malformed(diag, kv.key, @typeName(T));
    if (T == Observed and !endpoint_valid(record.endpoint)) {
        return malformed(diag, kv.key, @typeName(T));
    }
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

const test_health: Health = .{
    .command = &.{ "/bin/check", "--quick" },
    .interval_ms = 2_000,
    .timeout_ms = 1_000,
    .failure_threshold = 3,
    .success_threshold = 1,
};

test "C3: services and replicas are version 4 only with health or a rollout" {
    // Goal: the oldest-version rule (docs/keys.md, "Versions"): a release before C3 reads every
    // service that sets neither. Method: encode with and without each, read back, compare.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    const plain: Service = .{
        .name = "hello",
        .image = "b3:51aa9c03",
        .replicas = 2,
        .command = &.{"run"},
        .generation = 3,
    };
    const plain_bytes = try encode(arena, plain, &diag);
    const plain_back = try read(Service, arena, kv_of("/s", plain_bytes), &diag);
    try testing.expectEqual(service_version_plain, plain_back.v);
    try testing.expect(plain_back.health == null and plain_back.rollout == null);
    try testing.expect(plain_back.rollout_policy().equal(.{}));

    var checked = plain;
    checked.health = test_health;
    checked.rollout = .{ .strategy = .recreate, .max_surge = 0, .on_failure = .pause };
    const checked_bytes = try encode(arena, checked, &diag);
    try testing.expect(std.mem.startsWith(u8, checked_bytes, "{\"v\":4,"));
    const checked_back = try read(Service, arena, kv_of("/s", checked_bytes), &diag);
    try testing.expect(health_equal(checked.health, checked_back.health));
    try testing.expect(checked_back.rollout_policy().equal(checked.rollout.?));
    try testing.expectEqual(RolloutOnFailure.pause, checked_back.rollout.?.on_failure);

    var rolled = plain;
    rolled.rollout = .{ .max_surge = 2 };
    const rolled_bytes = try encode(arena, rolled, &diag);
    try testing.expect(std.mem.startsWith(u8, rolled_bytes, "{\"v\":4,"));

    const replica: Replica = .{
        .id = "hello-1",
        .service = "hello",
        .generation = 3,
        .image = "b3:51aa9c03",
        .command = &.{"run"},
    };
    const replica_plain = try encode(arena, replica, &diag);
    try testing.expect(std.mem.startsWith(u8, replica_plain, "{\"v\":3,"));
    var probed = replica;
    probed.health = test_health;
    const probed_bytes = try encode(arena, probed, &diag);
    try testing.expect(std.mem.startsWith(u8, probed_bytes, "{\"v\":4,"));
    const probed_back = try read(Replica, arena, kv_of("/r", probed_bytes), &diag);
    try testing.expect(health_equal(probed.health, probed_back.health));
    // A change of health is a change of what a replica runs.
    try testing.expect(replica_runs_service(&probed_back, &checked));
    try testing.expect(!replica_runs_service(&replica, &checked));
}

test "C3: an observation is version 3 only with a health verdict" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    const seen: Observed = .{
        .replica = "hello-1",
        .node = "n1",
        .generation = 3,
        .status = .running,
        .reported_at_ms = 5,
    };
    try testing.expect(std.mem.startsWith(u8, try encode(arena, seen, &diag), "{\"v\":2,"));
    var judged = seen;
    judged.health = .unhealthy;
    judged.health_failures = 3;
    judged.last_probe_exit = 1;
    const judged_bytes = try encode(arena, judged, &diag);
    try testing.expect(std.mem.startsWith(u8, judged_bytes, "{\"v\":3,"));
    const judged_back = try read(Observed, arena, kv_of("/o", judged_bytes), &diag);
    try testing.expectEqual(HealthState.unhealthy, judged_back.health.?);
    try testing.expectEqual(@as(u32, 3), judged_back.health_failures.?);
    try testing.expectEqual(@as(u8, 1), judged_back.last_probe_exit.?);
    try testing.expectEqual(HealthState.unhealthy, observed_health(&judged_back));
    // A verdict in a record older than version 3 is not one: no build wrote it.
    const old_text =
        \\{"v":2,"replica":"hello-1","node":"n1","generation":3,"status":"running",
    ++
        \\"reported_at_ms":5,"health":"healthy"}
    ;
    const old_back = try read(Observed, arena, kv_of("/o", old_text), &diag);
    try testing.expectEqual(HealthState.unknown, observed_health(&old_back));
    // An exit code is 0 to 255.
    const wide_text =
        \\{"v":3,"replica":"hello-1","node":"n1","generation":3,"status":"running",
    ++
        \\"reported_at_ms":5,"health":"healthy","last_probe_exit":256}
    ;
    try testing.expectError(error.Malformed, read(Observed, arena, kv_of("/o", wide_text), &diag));
}

test "C3: history and rollout records encode and read back" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    const service: Service = .{
        .name = "hello",
        .image = "b3:51aa9c03",
        .replicas = 2,
        .command = &.{"run"},
        .env = &.{.{ "GREETING", "hi" }},
        .generation = 7,
        .health = test_health,
        .applied_by = "ana",
        .request_id = "r7",
    };
    var history = history_of(&service, 1_761_350_000_123);
    history.reason = .rollback;
    history.restores = 5;
    const key = history_key("hello", 7);
    try testing.expectEqualStrings("/history/hello/7", key.slice());
    try testing.expectEqual(@as(?u64, 7), history_generation(key.slice()));
    const history_bytes = try encode(arena, history, &diag);
    const history_back = try read(History, arena, kv_of(key.slice(), history_bytes), &diag);
    try testing.expectEqual(@as(u64, 7), history_back.generation);
    try testing.expectEqual(@as(?u64, 5), history_back.restores);
    try testing.expectEqual(HistoryReason.rollback, history_back.reason);
    try testing.expect(health_equal(service.health, history_back.health));
    try testing.expect(pairs_equal(service.env, history_back.env));

    const rollout: Rollout = .{
        .service = "hello",
        .service_created = 40,
        .from = 6,
        .to = 7,
        .phase = .progressing,
        .started_at_ms = 10,
        .deadline_at_ms = 600_010,
        .budget = .{ .start = 1, .retire = 0 },
        .cause_decision = "0000000000000001-0000",
    };
    const rollout_key_value = rollout_key("hello");
    try testing.expectEqualStrings("/rollouts/hello", rollout_key_value.slice());
    const rollout_bytes = try encode(arena, rollout, &diag);
    const rollout_back = try read(Rollout, arena, kv_of("/rollouts/hello", rollout_bytes), &diag);
    try testing.expectEqual(RolloutPhase.progressing, rollout_back.phase);
    try testing.expectEqual(@as(u32, 1), rollout_back.budget.start);
    // A rollout belongs to one incarnation of its service: not to one created again, nor to none.
    try testing.expect(rollout_of(&rollout_back, 40));
    try testing.expect(!rollout_of(&rollout_back, 41));
    try testing.expect(!rollout_of(&rollout_back, null));
}

test "C3: a history key names one generation, in decimal, with no leading zero" {
    try testing.expectEqual(@as(?u64, 12), history_generation("/history/hello/12"));
    try testing.expectEqual(@as(?u64, null), history_generation("/history/hello/012"));
    try testing.expectEqual(@as(?u64, null), history_generation("/history/hello/"));
    try testing.expectEqual(@as(?u64, null), history_generation("/history/hello/x1"));
    try testing.expectEqual(@as(?u64, null), history_generation("/services/hello"));
    try testing.expectEqualStrings("/history/hello/", history_prefix("hello").slice());
}

/// The store a build before C3 (main f49041a) wrote, with C2's `source` (src/testdata/README.md).
const b3_store = @embedFile("testdata/b3_store.txt");

test "records a build before C3 wrote still read" {
    // Goal: a stored value is read by the next release. Method: read every record of a store the
    // last release before C3 produced (services with env, limits and a source, a generation bump,
    // a held replica) as the type its key says: services and replicas at version 3, with no health
    // and the default rollout; observed and decisions at version 2.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    var seen: [5]u32 = @splat(0);
    var lines = std.mem.splitScalar(u8, b3_store, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t').?;
        const kv = kv_of(line[0..tab], line[tab + 1 ..]);
        if (std.mem.startsWith(u8, kv.key, prefix_services)) {
            const record = try read(Service, arena, kv, &diag);
            try testing.expectEqual(service_version_plain, record.v);
            try testing.expect(record.health == null);
            try testing.expect(record.rollout_policy().equal(.{}));
            seen[0] += 1;
        } else if (std.mem.startsWith(u8, kv.key, prefix_replicas)) {
            const record = try read(Replica, arena, kv, &diag);
            try testing.expectEqual(service_version_plain, record.v);
            try testing.expect(record.health == null);
            seen[1] += 1;
        } else if (std.mem.startsWith(u8, kv.key, prefix_observed)) {
            const record = try read(Observed, arena, kv, &diag);
            try testing.expectEqual(@as(u32, 2), record.v);
            seen[2] += 1;
        } else if (std.mem.startsWith(u8, kv.key, prefix_decisions)) {
            _ = try read(Decision, arena, kv, &diag);
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
    const observed = "{\"v\":5,\"replica\":\"hello-1\",\"node\":\"node1\",\"generation\":1," ++
        "\"status\":\"running\",\"reported_at_ms\":5}";
    const kv = kv_of("/observed/node1/hello-1", observed);
    try testing.expectError(error.Malformed, read(Observed, arena, kv, &diag));
    try testing.expectEqual(codes.Code.E0303, diag.code.?);
    try testing.expectEqualStrings(
        "the value at /observed/node1/hello-1 is version 5; this release reads up to version 4",
        diag.last_cause().?,
    );
    // Version 1 of a record that C1 has not changed is the newest there is.
    diag.reset();
    const node_kv = kv_of("/nodes/n", "{\"v\":2,\"name\":\"n\",\"capacity\":{\"cpu_millis\":1," ++
        "\"memory_bytes\":1}}");
    try testing.expectError(error.Malformed, read(Node, arena, node_kv, &diag));
    try testing.expectEqual(codes.Code.E0303, diag.code.?);
}

test "source round-trips at version 3 and a version 6 service is refused" {
    // Goal: `source` is stored and read back, absent means empty, and a newer service is named.
    // Method: encode a service with and without it, read both back, then read a v6 value.
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
    const newer = "{\"v\":6,\"name\":\"hello\"}";
    const newer_kv = kv_of("/services/hello", newer);
    try testing.expectError(error.Malformed, read(Service, arena, newer_kv, &diag));
    try testing.expectEqual(codes.Code.E0303, diag.code.?);
    try testing.expectEqualStrings(
        "the value at /services/hello is version 6; this release reads up to version 5",
        diag.last_cause().?,
    );
}

test "services and observations written before C4 still read, with no mesh members" {
    // Goal: the slice's test "old records still read". Method: a version 3 and a version 4
    // service, and a version 3 observation, as C2 and C3 wrote them, read back without an
    // address, grants or endpoint; a v5 service with a bad address or grant, or a v4 observation
    // with a bad endpoint, is malformed (ZC-E0301), not taken in.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diag = undefined;
    diag.reset();
    const service_tail = "\"name\":\"hello\",\"image\":\"b3:51aa9c03\",\"replicas\":1," ++
        "\"command\":[\"run\"],\"generation\":2}";
    inline for (.{ "{\"v\":3,", "{\"v\":4," }) |head| {
        const old = try read(Service, arena, kv_of("/services/hello", head ++ service_tail), &diag);
        try testing.expectEqual(@as(?[]const u8, null), old.mesh_address);
        try testing.expectEqual(@as(usize, 0), old.allow.len);
    }
    const observed = "{\"v\":3,\"replica\":\"hello-1\",\"node\":\"node1\",\"generation\":1," ++
        "\"status\":\"running\",\"reported_at_ms\":5,\"health\":\"healthy\"}";
    const seen = try read(Observed, arena, kv_of("/observed/node1/hello-1", observed), &diag);
    try testing.expectEqual(@as(?[]const u8, null), seen.endpoint);
    const bad_services = [_][]const u8{
        "{\"v\":5,\"mesh_address\":\"127.77.0.0\"," ++ service_tail,
        "{\"v\":5,\"mesh_address\":\"10.0.0.1\"," ++ service_tail,
        "{\"v\":5,\"allow\":[{\"from\":\"web\",\"port\":0}]," ++ service_tail,
        "{\"v\":5,\"allow\":[{\"from\":\"hello\",\"port\":80}]," ++ service_tail,
    };
    for (bad_services) |bytes| {
        diag.reset();
        const kv = kv_of("/services/hello", bytes);
        try testing.expectError(error.Malformed, read(Service, arena, kv, &diag));
        try testing.expectEqual(codes.Code.E0301, diag.code.?);
    }
    const bad_endpoints = [_][]const u8{
        "node1", "node1:0", "node1:65536", ":80", "a b:80", "node1:+80", "node1:",
    };
    for (bad_endpoints) |endpoint| {
        diag.reset();
        const bytes = try std.fmt.allocPrint(arena, "{{\"v\":4,\"replica\":\"hello-1\"," ++
            "\"node\":\"node1\",\"generation\":1,\"status\":\"running\"," ++
            "\"reported_at_ms\":5,\"endpoint\":\"{s}\"}}", .{endpoint});
        const kv = kv_of("/observed/node1/hello-1", bytes);
        try testing.expectError(error.Malformed, read(Observed, arena, kv, &diag));
        try testing.expectEqual(codes.Code.E0301, diag.code.?);
    }
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
        JobObserved,   History,    Rollout,
        MeshAddressNext, MeshAddressHold,
    }) |T| {
        var value = std.mem.zeroes(T);
        value.v = version_current(T);
        // A replica's assignment: `read` refuses one with neither a service nor a job.
        if (T == Assigned) value.service = "s";
        // A service or replica is written at version 4 only with a health check (`encode`).
        if (T == Service or T == Replica) value.health = test_health;
        // A service is written at version 5 only with a mesh member, an observation at version 4
        // only with an endpoint (C4).
        if (T == Service) value.mesh_address = "127.77.0.1";
        if (T == Observed) value.health = .healthy;
        if (T == Observed) value.endpoint = "node1:30000";
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
