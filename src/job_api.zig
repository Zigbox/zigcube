//! The job API's logic (docs/briefs/b1.md, "API, CLI, console"; docs/api.md, "Jobs"): create a job
//! (validation, idempotency, admission, the input), read one, list, and cancel. The API writes
//! `/jobs/`, `/job-input/` and `/job-admission` (src/writers.zig); the job controller, a later
//! slice, takes it from there. Core code: functions over `Store` and `Clock`, no shell.
//!
//! **A refusal names its field.** ZC-E0130 says which field broke which limit. The run record the
//! job controller will write (`records.JobRun`, at most `job_run_bytes_max` encoded) is measured
//! here, on its escaped size, before anything is written, so `records.encode` never reaches
//! ZC-B0005 for a job this module accepted: JSON escaping turns one control byte into six, and
//! the raw sizes of `command` and `env` do not bound the encoded run.
//!
//! **Idempotency.** The same spec under the same name is a no-op that returns the job; a
//! different one is ZC-E0131. The compare covers the spec fields only, never `created_at_ms`,
//! `applied_by`, `submit_by_ms` or `cancel_requested`.

const std = @import("std");
const assert = std.debug.assert;
const c1_teeth = @import("c1_teeth.zig");
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const evidence = @import("evidence.zig");
const records = @import("records.zig");
const store = @import("store.zig");
const apply_mod = @import("apply.zig");

const Context = controller.Context;

pub const Error = controller.Error || error{Refused};

pub const actor = "api";

/// A job as a client submits it. `input` is decoded.
pub const Input = struct {
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
    /// The request named a `relay` or a `placement`: refused, they are not built yet.
    relay: bool = false,
    placement: bool = false,
    applied_by: []const u8,
    request_id: []const u8,
};

pub const Created = struct {
    job: records.Job,
    revision: store.Revision,
    decision: []const u8,
};

pub const CreateResult = union(enum) {
    /// Written: a new job.
    created: Created,
    /// The same spec under the same name: nothing was written.
    same: records.Job,
    /// The admission record or the name changed while this was made; nothing was written.
    conflict,
};

fn no_memory(diag: *@import("diag.zig").Diag) controller.Error {
    return @import("store_failures.zig").no_memory(diag);
}

// ---- Validation --------------------------------------------------------------------------------

fn refuse(
    ctx: *const Context,
    comptime field: []const u8,
    comptime format: []const u8,
    args: anytype,
) error{Refused} {
    assert(ctx.diag.code == null);
    ctx.diag.raise(.E0130);
    ctx.diag.cause(field ++ ": " ++ format, args);
    ctx.diag.fix(.{ .sentence = "correct the field and submit the job again" });
    return error.Refused;
}

fn not_built(ctx: *const Context, comptime field: []const u8) error{Refused} {
    return refuse(ctx, field, "is not built yet; a job is accepted without it", .{});
}

/// A bare variable name: letters, digits and '_', not starting with a digit.
pub fn variable_name_valid(name: []const u8) bool {
    if (name.len == 0 or name.len > constants.job_input_env_bytes_max) return false;
    for (name, 0..) |byte, index| {
        const letter = std.ascii.isAlphabetic(byte) or byte == '_';
        if (letter) continue;
        if (index > 0 and std.ascii.isDigit(byte)) continue;
        return false;
    }
    return true;
}

fn has_nul(text: []const u8) bool {
    return std.mem.indexOfScalar(u8, text, 0) != null;
}

fn validate_command(ctx: *const Context, input: Input) Error!void {
    const words = input.command;
    if (words.len == 0 or words.len > constants.job_command_words_max) {
        return refuse(ctx, "command", "must have 1 to {d} words, it has {d}", .{
            constants.job_command_words_max, words.len,
        });
    }
    if (words[0].len == 0) return refuse(ctx, "command", "the first word is empty", .{});
    for (words) |word| {
        if (has_nul(word)) return refuse(ctx, "command", "a word holds a NUL byte", .{});
    }
}

fn validate_env(ctx: *const Context, input: Input) Error!void {
    if (input.env.len > constants.runtime_env_count_max) {
        return refuse(ctx, "env", "at most {d} variables, it has {d}", .{
            constants.runtime_env_count_max, input.env.len,
        });
    }
    // The input is given in one more variable, and the runtime takes `runtime_env_count_max`.
    if (input.input != null and input.env.len >= constants.runtime_env_count_max) {
        return refuse(ctx, "env", "at most {d} variables with an input, it has {d}", .{
            constants.runtime_env_count_max - 1, input.env.len,
        });
    }
    var bytes: usize = 0;
    for (input.env, 0..) |pair, index| {
        const name = pair[0];
        if (name.len == 0) return refuse(ctx, "env", "a variable has no name", .{});
        if (has_nul(name) or has_nul(pair[1])) {
            return refuse(ctx, "env", "{s} holds a NUL byte", .{name});
        }
        if (std.mem.indexOfScalar(u8, name, '=') != null) {
            return refuse(ctx, "env", "the name {s} holds '='", .{name});
        }
        for (input.env[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier[0], name)) {
                return refuse(ctx, "env", "{s} is set twice", .{name});
            }
        }
        bytes += name.len + pair[1].len;
    }
    if (bytes > constants.job_env_bytes_max) {
        return refuse(ctx, "env", "names and values take {d} bytes, at most {d}", .{
            bytes, constants.job_env_bytes_max,
        });
    }
}

fn validate_labels(ctx: *const Context, input: Input) Error!void {
    if (input.labels.len > constants.job_labels_max) {
        return refuse(ctx, "labels", "at most {d}, it has {d}", .{
            constants.job_labels_max, input.labels.len,
        });
    }
    for (input.labels) |pair| {
        if (pair[0].len == 0) return refuse(ctx, "labels", "a label has no key", .{});
        // The controller sets `zcube.replica` and `zcube.job` on the container itself.
        if (std.mem.startsWith(u8, pair[0], "zcube.")) {
            const problem = "keys starting with zcube. are reserved ({s})";
            return refuse(ctx, "labels", problem, .{pair[0]});
        }
        if (has_nul(pair[0]) or has_nul(pair[1])) {
            return refuse(ctx, "labels", "{s} holds a NUL byte", .{pair[0]});
        }
        if (pair[0].len > constants.label_key_bytes_max) {
            return refuse(ctx, "labels", "a key is over {d} bytes", .{
                constants.label_key_bytes_max,
            });
        }
        if (pair[1].len > constants.label_value_bytes_max) {
            return refuse(ctx, "labels", "the value of {s} is over {d} bytes", .{
                pair[0], constants.label_value_bytes_max,
            });
        }
        if (std.mem.indexOfScalar(u8, pair[0], '=') != null) {
            return refuse(ctx, "labels", "the key {s} holds '='", .{pair[0]});
        }
    }
    for (input.labels, 0..) |pair, index| {
        for (input.labels[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier[0], pair[0])) {
                return refuse(ctx, "labels", "{s} is set twice", .{pair[0]});
            }
        }
    }
}

fn limits_in_bounds(limits: records.JobLimits) bool {
    if (limits.cpu_millis) |value| {
        if (value < constants.job_limit_cpu_millis_min) return false;
        if (value > constants.job_limit_cpu_millis_max) return false;
    }
    if (limits.memory_bytes) |value| {
        if (value < constants.job_limit_memory_bytes_min) return false;
        if (value > constants.job_limit_memory_bytes_max) return false;
    }
    if (limits.pids) |value| {
        if (value < constants.job_limit_pids_min) return false;
        if (value > constants.job_limit_pids_max) return false;
    }
    return true;
}

fn validate_limits(ctx: *const Context, limits: records.JobLimits) Error!void {
    if (limits.cpu_millis) |value| {
        if (value < constants.job_limit_cpu_millis_min or
            value > constants.job_limit_cpu_millis_max)
        {
            return refuse(ctx, "limits.cpu_millis", "must be {d} to {d}, it is {d}", .{
                constants.job_limit_cpu_millis_min, constants.job_limit_cpu_millis_max, value,
            });
        }
    }
    if (limits.memory_bytes) |value| {
        if (value < constants.job_limit_memory_bytes_min or
            value > constants.job_limit_memory_bytes_max)
        {
            return refuse(ctx, "limits.memory_bytes", "must be {d} to {d}, it is {d}", .{
                constants.job_limit_memory_bytes_min, constants.job_limit_memory_bytes_max, value,
            });
        }
    }
    if (limits.pids) |value| {
        if (value < constants.job_limit_pids_min or value > constants.job_limit_pids_max) {
            return refuse(ctx, "limits.pids", "must be {d} to {d}, it is {d}", .{
                constants.job_limit_pids_min, constants.job_limit_pids_max, value,
            });
        }
    }
}

fn validate_input(ctx: *const Context, input: Input) Error!void {
    const text = input.input orelse {
        if (input.input_env != null) {
            return refuse(ctx, "input_env", "names a variable, but there is no input", .{});
        }
        return;
    };
    if (text.len > constants.job_input_bytes_max) {
        return refuse(ctx, "input", "is {d} bytes, at most {d}", .{
            text.len, constants.job_input_bytes_max,
        });
    }
    if (has_nul(text)) return refuse(ctx, "input", "holds a NUL byte", .{});
    if (!std.unicode.utf8ValidateSlice(text)) return refuse(ctx, "input", "is not UTF-8", .{});
    const variable = input.input_env orelse {
        const problem = "is required with an input: the variable it is given in";
        return refuse(ctx, "input_env", problem, .{});
    };
    if (!variable_name_valid(variable)) {
        const problem = "must be a variable name of 1 to {d} letters, digits or '_'";
        return refuse(ctx, "input_env", problem, .{
            constants.job_input_env_bytes_max,
        });
    }
    for (input.env) |pair| {
        if (std.mem.eql(u8, pair[0], variable)) {
            return refuse(ctx, "input_env", "{s} is also set in env", .{variable});
        }
    }
}

fn validate_times(ctx: *const Context, input: Input, now_ms: u64) Error!void {
    if (input.deadline_ms == 0 or input.deadline_ms > constants.job_deadline_ms_max) {
        return refuse(ctx, "deadline_ms", "must be 1 to {d} (24 hours), it is {d}", .{
            constants.job_deadline_ms_max, input.deadline_ms,
        });
    }
    if (input.grace_ms > constants.job_grace_ms_max) {
        return refuse(ctx, "grace_ms", "at most {d}, it is {d}", .{
            constants.job_grace_ms_max, input.grace_ms,
        });
    }
    if (input.submit_by_ms > now_ms + constants.job_submit_window_ms_max) {
        return refuse(ctx, "submit_by_ms", "is more than {d} ms ahead of the server's clock", .{
            constants.job_submit_window_ms_max,
        });
    }
}

/// `GET /v1/jobs/watch` takes the place of a job of this name, so no job has it.
pub const reserved_name = "watch";

/// The checks that need no store. A job that passes them is one `create` can try to admit.
/// `submit_by_ms` having passed is not among them: it means a job that does not exist yet is too
/// late, and a late retry of a job that does exist is a success (`create` checks it).
pub fn validate(ctx: *const Context, input: Input, now_ms: u64) Error!void {
    try validate_shape(ctx, input, now_ms);
    try validate_limits(ctx, input.limits);
}

/// Every check of `validate` but the bounds of `limits`, which `create` may skip for a retry of a
/// job stored before they existed.
fn validate_shape(ctx: *const Context, input: Input, now_ms: u64) Error!void {
    if (records.name_problem(input.name, constants.service_name_bytes_max) != null) {
        const problem = "must be 1 to {d} lowercase letters, digits or '-' (none at either end)";
        return refuse(ctx, "name", problem, .{
            constants.service_name_bytes_max,
        });
    }
    if (std.mem.eql(u8, input.name, reserved_name)) {
        return refuse(ctx, "name", "'{s}' is the route of the jobs watch; choose another", .{
            reserved_name,
        });
    }
    if (input.image.len == 0 or input.image.len > constants.image_digest_bytes_max) {
        return refuse(ctx, "image", "must be 1 to {d} bytes", .{constants.image_digest_bytes_max});
    }
    if (apply_mod.source_problem(input.source)) |problem| {
        return refuse(ctx, "source", "{s}", .{problem});
    }
    try validate_command(ctx, input);
    try validate_env(ctx, input);
    try validate_labels(ctx, input);
    if (input.retries > 0) return not_built(ctx, "retries");
    if (input.relay) return not_built(ctx, "relay");
    if (input.placement) return not_built(ctx, "placement");
    try validate_times(ctx, input, now_ms);
    try validate_input(ctx, input);
}

fn expired(ctx: *const Context, name: []const u8, submit_by_ms: u64, now_ms: u64) error{Refused} {
    assert(ctx.diag.code == null);
    ctx.diag.raise(.E0134);
    ctx.diag.cause("submit_by_ms {d} passed {d} ms ago", .{ submit_by_ms, now_ms - submit_by_ms });
    ctx.diag.fix_with(
        "look for the job an earlier attempt may have made, then submit again",
        "zcube job get {s}",
        .{name},
    );
    return error.Refused;
}

// ---- The run record's size ---------------------------------------------------------------------

fn json_bytes(ctx: *const Context, value: anytype) Error!usize {
    const text = std.json.Stringify.valueAlloc(ctx.arena, value, .{
        .emit_null_optional_fields = false,
    }) catch return @import("store_failures.zig").no_memory(ctx.diag);
    return text.len;
}

/// The run the job controller will write for `job`, as large as it can get: stopped, with the
/// longest time. What the agents' runs reply is sized by this, so it is measured on the escaped
/// JSON (`records.encode` would otherwise stop it at ZC-B0005).
pub fn run_of(job: *const records.Job, id: []const u8) records.JobRun {
    return .{
        .id = id,
        .job = job.name,
        .image = job.image,
        .source = job.source,
        .command = job.command,
        .env = job.env,
        .limits = job.limits,
        .deadline_ms = job.deadline_ms,
        .grace_ms = job.grace_ms,
        .labels = job.labels,
        .input_env = job.input_env,
        .input_digest = job.input_digest,
        .input_bytes = job.input_bytes,
        .start_by_ms = job.created_at_ms + job.deadline_ms,
        .created_at_ms = job.created_at_ms,
        .stop = .{ .cause = .not_started, .at_ms = std.math.maxInt(u64) },
    };
}

/// Refuses (ZC-E0130, naming the field) a job whose run would encode over `job_run_bytes_max`.
fn check_run_size(ctx: *const Context, job: *const records.Job) Error!void {
    var id_buffer: [constants.job_run_id_bytes_max]u8 = undefined;
    const run = run_of(job, records.job_run_id(&id_buffer, job.name));
    const total = try json_bytes(ctx, run);
    if (total <= constants.job_run_bytes_max) return;
    // Name the member that takes the most room once escaped.
    const Member = struct { name: []const u8, bytes: usize };
    const members = [_]Member{
        .{ .name = "command", .bytes = try json_bytes(ctx, job.command) },
        .{ .name = "env", .bytes = try json_bytes(ctx, job.env) },
        .{ .name = "labels", .bytes = try json_bytes(ctx, job.labels) },
        .{ .name = "source", .bytes = try json_bytes(ctx, job.source) },
        .{ .name = "image", .bytes = try json_bytes(ctx, job.image) },
    };
    var biggest = members[0];
    for (members[1..]) |member| {
        if (member.bytes > biggest.bytes) biggest = member;
    }
    assert(ctx.diag.code == null);
    ctx.diag.raise(.E0130);
    ctx.diag.cause(
        "{s}: the run record would take {d} bytes once escaped (a control character takes six), " ++
            "at most {d}; {s} takes {d} of them",
        .{ biggest.name, total, constants.job_run_bytes_max, biggest.name, biggest.bytes },
    );
    ctx.diag.fix(.{ .sentence = "shorten the field, or avoid control characters in it" });
    return error.Refused;
}

// ---- Create ------------------------------------------------------------------------------------

const hour_ms: u64 = 60 * 60 * 1000;

fn spec_equal(old: *const records.Job, new: *const records.Job) bool {
    if (!std.mem.eql(u8, old.image, new.image)) return false;
    if (!std.mem.eql(u8, old.source, new.source)) return false;
    if (!strings_equal(old.command, new.command)) return false;
    if (!pairs_equal(old.env, new.env)) return false;
    if (!pairs_equal(old.labels, new.labels)) return false;
    if (!std.meta.eql(old.limits, new.limits)) return false;
    if (old.deadline_ms != new.deadline_ms or old.retries != new.retries) return false;
    if (old.grace_ms != new.grace_ms) return false;
    if (!optional_equal(old.input_env, new.input_env)) return false;
    return optional_equal(old.input_digest, new.input_digest);
}

fn optional_equal(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn strings_equal(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    return true;
}

/// Pairs compare as sets: every pair of each side is on the other, in any order. New jobs have
/// unique keys (`validate_env` and `validate_labels` refuse a duplicate), but a job stored before
/// that check may repeat one; a repeated pair is the same pair, and a key with two values on one
/// side only is a different spec.
fn pairs_equal(a: []const records.Pair, b: []const records.Pair) bool {
    for (a) |left| {
        if (!has_pair(b, left)) return false;
    }
    for (b) |right| {
        if (!has_pair(a, right)) return false;
    }
    return true;
}

fn has_pair(pairs: []const records.Pair, wanted: records.Pair) bool {
    for (pairs) |pair| {
        if (std.mem.eql(u8, pair[0], wanted[0]) and std.mem.eql(u8, pair[1], wanted[1])) {
            return true;
        }
    }
    return false;
}

fn too_many(ctx: *const Context, comptime format: []const u8, args: anytype) error{Refused} {
    assert(ctx.diag.code == null);
    ctx.diag.raise(.E0132);
    ctx.diag.cause(format, args);
    ctx.diag.fix(.{
        .sentence = "wait for jobs to end, or cancel some, then submit again",
        .command = "zcube job list",
    });
    return error.Refused;
}

fn digest_of(ctx: *const Context, text: []const u8) controller.Error![]const u8 {
    var raw: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &raw, .{});
    const hex = std.fmt.bytesToHex(raw, .lower);
    return controller.format(ctx, "sha256:{s}", .{&hex});
}

fn base64_of(ctx: *const Context, text: []const u8) controller.Error![]const u8 {
    const encoder = std.base64.standard.Encoder;
    const buffer = ctx.arena.alloc(u8, encoder.calcSize(text.len)) catch
        return @import("store_failures.zig").no_memory(ctx.diag);
    return encoder.encode(buffer, text);
}

/// The admission record after one more create at `now_ms`: hours older than the window dropped.
fn admit_one(
    ctx: *const Context,
    old: records.JobAdmission,
    now_ms: u64,
) controller.Error!records.JobAdmission {
    const hour = now_ms / hour_ms;
    var kept: std.ArrayList(records.HourCount) = .empty;
    // A bucket ahead of the clock was written before the clock stepped back. Its jobs were
    // admitted all the same, so it is relabelled as the current hour with its count (it counts
    // against the cap now, and leaves the window with the hour it is relabelled to).
    var ahead: u32 = 0;
    for (old.hours) |entry| {
        if (entry.hour + constants.job_admission_window_h <= hour) continue;
        if (entry.hour > hour) {
            ahead += entry.count;
            continue;
        }
        kept.append(ctx.arena, entry) catch return no_memory(ctx.diag);
    }
    const last = if (kept.items.len > 0) &kept.items[kept.items.len - 1] else null;
    if (last != null and last.?.hour == hour) {
        last.?.count += ahead + 1;
    } else {
        kept.append(ctx.arena, .{ .hour = hour, .count = ahead + 1 }) catch
            return @import("store_failures.zig").no_memory(ctx.diag);
    }
    return .{ .admitted = old.admitted + 1, .hours = kept.items };
}

fn window_count(admission: records.JobAdmission, now_ms: u64) u64 {
    const hour = now_ms / hour_ms;
    var sum: u64 = 0;
    for (admission.hours) |entry| {
        // A bucket ahead of the clock counts as the current hour's (see `admit_one`).
        if (entry.hour + constants.job_admission_window_h > hour) sum += entry.count;
    }
    return sum;
}

/// Creates the job, or finds the one this is a retry of. See the module doc for the order.
pub fn create(
    ctx: *const Context,
    source: *controller.DecisionSource,
    input: Input,
) Error!CreateResult {
    const now_ms = ctx.clock.now_ms();
    try validate_shape(ctx, input, now_ms);
    const digest = if (input.input) |text| try digest_of(ctx, text) else null;
    const job: records.Job = .{
        .name = input.name,
        .image = input.image,
        .source = input.source,
        .command = input.command,
        .env = input.env,
        .limits = input.limits,
        .deadline_ms = input.deadline_ms,
        .retries = input.retries,
        .labels = input.labels,
        .grace_ms = input.grace_ms,
        .input_env = input.input_env,
        .input_digest = digest,
        .input_bytes = if (input.input) |text| text.len else null,
        .submit_by_ms = input.submit_by_ms,
        .created_at_ms = now_ms,
        .applied_by = input.applied_by,
    };
    const key = records.job_key(input.name);
    if (!limits_in_bounds(input.limits)) {
        // A job stored before the bounds existed (#178) may carry limits outside them. Its retry
        // is still a retry and gets the original answer; any other job, new or different, is
        // refused for its limits as it always was.
        const stored = try ctx.store.get(ctx.arena, key.slice(), null, ctx.diag);
        if (stored.kv) |kv| {
            const old = try records.read(records.Job, ctx.arena, kv, ctx.diag);
            if (spec_equal(&old, &job)) return .{ .same = old };
        }
        try validate_limits(ctx, input.limits);
        unreachable; // `limits_in_bounds` is false, so `validate_limits` refused above.
    }
    try check_run_size(ctx, &job);
    const found = try ctx.store.get(ctx.arena, key.slice(), null, ctx.diag);
    if (found.kv) |kv| {
        const old = try records.read(records.Job, ctx.arena, kv, ctx.diag);
        if (spec_equal(&old, &job)) return .{ .same = old };
        return different(ctx, input.name);
    }
    if (now_ms > input.submit_by_ms) return expired(ctx, input.name, input.submit_by_ms, now_ms);
    return admit(ctx, source, input, job, key);
}

fn different(ctx: *const Context, name: []const u8) error{Refused} {
    assert(ctx.diag.code == null);
    ctx.diag.raise(.E0131);
    ctx.diag.cause("job {s} exists with a different spec", .{name});
    ctx.diag.fix_with("look at the job that exists", "zcube job get {s}", .{name});
    return error.Refused;
}

fn admit(
    ctx: *const Context,
    source: *controller.DecisionSource,
    input: Input,
    job: records.Job,
    key: records.Key,
) Error!CreateResult {
    const now_ms = job.created_at_ms;
    const admission_at = try ctx.store.get(ctx.arena, records.key_job_admission, null, ctx.diag);
    var admission: records.JobAdmission = .{};
    var admission_revision: store.Revision = 0;
    if (admission_at.kv) |kv| {
        admission = try records.read(records.JobAdmission, ctx.arena, kv, ctx.diag);
        admission_revision = kv.mod_revision;
    }
    const endings_at = try ctx.store.get(ctx.arena, records.key_job_endings, null, ctx.diag);
    var ended: u64 = 0;
    if (endings_at.kv) |kv| {
        ended = (try records.read(records.JobEndings, ctx.arena, kv, ctx.diag)).ended;
    }
    // `/job-endings` only grows, so a read older than the admission compare only under-counts the
    // jobs that ended: the room it reports is never more than there is.
    const live = admission.admitted -| ended;
    if (live >= constants.jobs_max) {
        return too_many(ctx, "{d} jobs have not ended, the most the cluster holds ({d})", .{
            live, constants.jobs_max,
        });
    }
    const recent = window_count(admission, now_ms);
    if (recent >= constants.job_admitted_window_max) {
        return too_many(
            ctx,
            "{d} jobs were created in the last {d} hours, the most that can be kept ({d})",
            .{ recent, constants.job_admission_window_h, constants.job_admitted_window_max },
        );
    }
    const next = try admit_one(ctx, admission, now_ms);
    const admitted: Admitted = .{ .next = next, .revision = admission_revision };
    return write_new(ctx, source, input, job, key, admitted);
}

const Admitted = struct { next: records.JobAdmission, revision: store.Revision };

fn write_new(
    ctx: *const Context,
    source: *controller.DecisionSource,
    input: Input,
    job: records.Job,
    key: records.Key,
    admitted: Admitted,
) Error!CreateResult {
    var batch: controller.Batch = .{};
    const job_at = try controller.key_copy(ctx, &key);
    batch.expect(job_at, 0);
    batch.expect(records.key_job_admission, admitted.revision);
    batch.put(job_at, try records.encode(ctx.arena, job, ctx.diag));
    if (input.input) |text| {
        const input_at = records.job_input_key(job.name);
        const stored: records.JobInput = .{ .base64 = try base64_of(ctx, text) };
        const bytes = try records.encode(ctx.arena, stored, ctx.diag);
        batch.put(try controller.key_copy(ctx, &input_at), bytes);
    }
    batch.put(records.key_job_admission, try records.encode(ctx.arena, admitted.next, ctx.diag));
    const reason = try controller.format(ctx, "{s} submitted job {s} (request {s})", .{
        input.applied_by, job.name, input.request_id,
    });
    const id = try controller.put_decision(ctx, source, .{
        .actor = actor,
        .action = "submit",
        .subject = .{ .kind = .job, .name = job.name },
        .reason = reason,
        .change = "created",
        .cause = .{ .kind = .desired, .key = job_at },
        .cause_evidence = try evidence.job(ctx, &job, input.request_id),
    }, &batch);
    return switch (try controller.commit(ctx, .api, &batch)) {
        .applied => |revision| .{ .created = .{
            .job = job,
            .revision = revision,
            .decision = try controller.format(ctx, "{s}", .{id.slice()}),
        } },
        .conflict => .conflict,
    };
}

// ---- Read --------------------------------------------------------------------------------------

fn no_job(ctx: *const Context, name: []const u8) error{Refused} {
    assert(ctx.diag.code == null);
    ctx.diag.raise(.E0133);
    ctx.diag.cause("no job named {s} is stored", .{name});
    ctx.diag.fix(.{ .sentence = "list the jobs that exist", .command = "zcube job list" });
    return error.Refused;
}

/// A job and where it stands. `status` is null until the job controller has written one.
pub const View = struct {
    job: records.Job,
    status: ?records.JobStatus,
    revision: store.Revision,
};

pub fn state_of(status: ?records.JobStatus) records.JobState {
    return if (status) |known| known.state else .pending;
}

fn name_checked(ctx: *const Context, name: []const u8) Error!void {
    if (records.name_problem(name, constants.service_name_bytes_max) != null) {
        return no_job(ctx, name);
    }
}

pub fn get(ctx: *const Context, name: []const u8) Error!View {
    try name_checked(ctx, name);
    const at = (try ctx.store.status(ctx.diag)).revision;
    return read_view(ctx, name, at);
}

fn read_view(ctx: *const Context, name: []const u8, at: store.Revision) Error!View {
    const key = records.job_key(name);
    const found = try ctx.store.get(ctx.arena, key.slice(), at, ctx.diag);
    const kv = found.kv orelse return no_job(ctx, name);
    const job = try records.read(records.Job, ctx.arena, kv, ctx.diag);
    const read = try read_status(ctx, name, at);
    return .{ .job = job, .status = read.status, .revision = at };
}

/// A job's status as read at one revision, with the revision of the record (0 if absent) so a
/// transaction can compare it.
const StatusRead = struct { status: ?records.JobStatus, revision: store.Revision };

fn read_status(ctx: *const Context, name: []const u8, at: store.Revision) Error!StatusRead {
    const key = records.job_status_key(name);
    const found = try ctx.store.get(ctx.arena, key.slice(), at, ctx.diag);
    const kv = found.kv orelse return .{ .status = null, .revision = 0 };
    const status = try records.read(records.JobStatus, ctx.arena, kv, ctx.diag);
    return .{ .status = status, .revision = kv.mod_revision };
}

/// The state of an existing job now: its status's, or `pending` while it has none. For the
/// replies that say a request changed nothing, so a client that retries after the job ended is
/// told so.
pub fn current_state(ctx: *const Context, name: []const u8) Error!records.JobState {
    try name_checked(ctx, name);
    const at = (try ctx.store.status(ctx.diag)).revision;
    return state_of((try read_status(ctx, name, at)).status);
}

pub const ListOptions = struct {
    state: ?records.JobState = null,
    /// `state=ended`: every terminal state.
    ended: bool = false,
    /// `key=value`, or a bare key for any value.
    label: ?[]const u8 = null,
    limit: u32,
    at: ?store.Revision = null,
    after: ?[]const u8 = null,
};

pub const Row = struct {
    name: []const u8,
    image: []const u8,
    state: records.JobState,
    node: ?[]const u8 = null,
    labels: []const records.Pair,
    created_at_ms: u64,
    deadline_ms: u64,
    cancel_requested: bool,
    end: ?records.JobEnd = null,
    /// The placement epoch the run was claimed under: with `name`, what identifies an ending.
    epoch: ?u64 = null,
    /// When the job reached its terminal state, as its status records it (set once, never changed):
    /// with `name` and `epoch`, the key that tells two endings of a reused name apart.
    ended_at_ms: ?u64 = null,
};

pub const Listing = struct {
    revision: store.Revision,
    rows: []const Row,
    /// Set when more jobs follow this page: pass it with `at = revision`.
    continue_after: ?[]const u8,
};

pub fn label_matches(labels: []const records.Pair, wanted: []const u8) bool {
    const split = std.mem.indexOfScalar(u8, wanted, '=');
    const key = if (split) |at| wanted[0..at] else wanted;
    for (labels) |pair| {
        if (!std.mem.eql(u8, pair[0], key)) continue;
        if (split == null) return true;
        if (std.mem.eql(u8, pair[1], wanted[split.? + 1 ..])) return true;
    }
    return false;
}

/// One page of jobs by name, at one revision. A filter keeps a subset of the page, so a page
/// may hold fewer rows than `limit` and still have a `continue_after`: follow it until it ends.
pub fn list(ctx: *const Context, options: ListOptions) Error!Listing {
    assert(options.limit > 0);
    assert(options.limit <= constants.store_list_limit_max);
    const page = try ctx.store.list(ctx.arena, .{
        .prefix = records.prefix_jobs,
        .at_revision = options.at,
        .limit = options.limit,
        .continue_after = options.after,
    }, ctx.diag);
    var rows: std.ArrayList(Row) = .empty;
    for (page.kvs) |kv| {
        const job = try records.read(records.Job, ctx.arena, kv, ctx.diag);
        if (options.label) |wanted| {
            if (!label_matches(job.labels, wanted)) continue;
        }
        const status = (try read_status(ctx, job.name, page.revision)).status;
        const state = state_of(status);
        if (options.state) |only| {
            if (state != only) continue;
        }
        if (options.ended) {
            if (!records.job_state_terminal(state)) continue;
        }
        rows.append(ctx.arena, .{
            .name = job.name,
            .image = job.image,
            .state = state,
            .node = if (status) |known| known.node else null,
            .labels = job.labels,
            .created_at_ms = job.created_at_ms,
            .deadline_ms = job.deadline_ms,
            .cancel_requested = job.cancel_requested != null,
            .end = if (status) |known| known.end else null,
            .epoch = if (status) |known| known.epoch else null,
            .ended_at_ms = if (status) |known| known.ended_at_ms else null,
        }) catch return @import("store_failures.zig").no_memory(ctx.diag);
    }
    return .{
        .revision = page.revision,
        .rows = rows.items,
        .continue_after = page.continue_after,
    };
}

// ---- Watch -------------------------------------------------------------------------------------

/// One change of a job's status, as `GET /v1/jobs/watch` reports it.
pub const WatchEvent = struct {
    /// "put" or "delete".
    type: []const u8,
    name: []const u8,
    /// The store revision of the change.
    revision: store.Revision,
    /// Absent on a delete.
    status: ?records.JobStatus = null,
};

/// The `/job-status/` events among `events`, decoded. With `label`, a change is kept only if the
/// job exists now and carries it: a deleted job, and the deletion of a status, match no label.
/// A status that cannot be decoded is an error, never skipped (a client would miss an ending).
pub fn watch_events(
    ctx: *const Context,
    events: []const store.Event,
    label: ?[]const u8,
) Error![]const WatchEvent {
    var found: std.ArrayList(WatchEvent) = .empty;
    for (events) |event| {
        if (!std.mem.startsWith(u8, event.kv.key, records.prefix_job_status)) continue;
        const name = event.kv.key[records.prefix_job_status.len..];
        if (label) |wanted| {
            if (event.kind == .delete) continue;
            const key = records.job_key(name);
            const got = try ctx.store.get(ctx.arena, key.slice(), null, ctx.diag);
            const kv = got.kv orelse continue;
            const job = try records.read(records.Job, ctx.arena, kv, ctx.diag);
            if (!label_matches(job.labels, wanted)) continue;
        }
        const status: ?records.JobStatus = switch (event.kind) {
            .put => try records.read(records.JobStatus, ctx.arena, event.kv, ctx.diag),
            .delete => null,
        };
        if (c1_teeth.job_gap and status != null and records.job_state_terminal(status.?.state) and
            event.kv.mod_revision % 2 == 0) continue;
        found.append(ctx.arena, .{
            .type = @tagName(event.kind),
            .name = name,
            .revision = event.kv.mod_revision,
            .status = status,
        }) catch return @import("store_failures.zig").no_memory(ctx.diag);
    }
    return found.items;
}

// ---- Cancel ------------------------------------------------------------------------------------

pub const CancelResult = union(enum) {
    /// The request was recorded: the job controller stops the run.
    accepted: struct {
        job: records.Job,
        revision: store.Revision,
        decision: []const u8,
        /// The job's state when the request was recorded.
        state: records.JobState,
    },
    /// A cancel was already recorded; nothing was written.
    already: records.Job,
    /// The job has ended; nothing was written.
    finished: View,
    conflict,
};

/// Records that `by` wants the job stopped (`cancel_requested`). A job that has ended is not
/// changed, and says how it ended.
pub fn cancel(
    ctx: *const Context,
    source: *controller.DecisionSource,
    name: []const u8,
    by: []const u8,
    request_id: []const u8,
) Error!CancelResult {
    try name_checked(ctx, name);
    const key = records.job_key(name);
    const found = try ctx.store.get(ctx.arena, key.slice(), null, ctx.diag);
    const kv = found.kv orelse return no_job(ctx, name);
    var job = try records.read(records.Job, ctx.arena, kv, ctx.diag);
    const at = (try ctx.store.status(ctx.diag)).revision;
    const read = try read_status(ctx, name, at);
    const status = read.status;
    if (status) |known| {
        if (records.job_state_terminal(known.state)) {
            return .{ .finished = .{ .job = job, .status = status, .revision = at } };
        }
    }
    if (job.cancel_requested != null) return .{ .already = job };
    job.cancel_requested = .{ .at_ms = ctx.clock.now_ms(), .by = by };
    var batch: controller.Batch = .{};
    batch.expect(key.slice(), kv.mod_revision);
    // The status decided the answer: if the run ended since, the cancel must not be recorded.
    const status_key = records.job_status_key(name);
    batch.expect(status_key.slice(), read.revision);
    batch.put(kv.key, try records.encode(ctx.arena, job, ctx.diag));
    const reason = try controller.format(ctx, "{s} asked to cancel job {s} (request {s})", .{
        by, name, request_id,
    });
    const id = try controller.put_decision(ctx, source, .{
        .actor = actor,
        .action = "cancel",
        .subject = .{ .kind = .job, .name = name },
        .reason = reason,
        .change = "cancel requested",
        .cause = .{ .kind = .desired, .key = kv.key },
        .cause_evidence = try evidence.job(ctx, &job, request_id),
    }, &batch);
    return switch (try controller.commit(ctx, .api, &batch)) {
        .applied => |revision| .{ .accepted = .{
            .job = job,
            .revision = revision,
            .decision = try controller.format(ctx, "{s}", .{id.slice()}),
            .state = state_of(status),
        } },
        .conflict => .conflict,
    };
}

// ---- Tests -------------------------------------------------------------------------------------

const testing = std.testing;
const ManualClock = @import("clock.zig").ManualClock;
const MemoryStore = @import("store_memory.zig").MemoryStore;
const Diag = @import("diag.zig").Diag;
const Code = @import("diag/codes.zig").Code;

const now_start: u64 = 1761350000123;

const Rig = struct {
    arena_state: std.heap.ArenaAllocator,
    manual: ManualClock,
    memory: *MemoryStore,
    diag: Diag,
    source: controller.DecisionSource,

    fn start(rig: *Rig) !void {
        rig.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        rig.manual = .{ .ms = now_start };
        rig.memory = try testing.allocator.create(MemoryStore);
        rig.memory.init(testing.allocator, rig.manual.clock());
        rig.diag.reset();
        rig.source = .{ .instance = 0 };
    }

    fn stop(rig: *Rig) void {
        rig.memory.deinit();
        testing.allocator.destroy(rig.memory);
        rig.arena_state.deinit();
    }

    fn context(rig: *Rig) Context {
        return .{
            .store = rig.memory.interface(),
            .clock = rig.manual.clock(),
            .arena = rig.arena_state.allocator(),
            .diag = &rig.diag,
        };
    }

    fn expect_code(rig: *Rig, code: Code) !void {
        try testing.expectEqual(code, rig.diag.code.?);
        rig.diag.reset();
    }
};

fn sample(name: []const u8) Input {
    return .{
        .name = name,
        .image = "b3:51aa9c03",
        .command = &.{ "sh", "-c", "echo hi" },
        .deadline_ms = 60_000,
        .submit_by_ms = now_start + 30_000,
        .applied_by = "alex@laptop",
        .request_id = "r-0001a4f",
    };
}

test "create writes the job, its input and a decision; the same spec again is the same job" {
    var rig: Rig = undefined;
    try rig.start();
    defer rig.stop();
    const ctx = rig.context();
    var input = sample("nightly");
    input.input = "hello\n";
    input.input_env = "PAYLOAD";
    const first = try create(&ctx, &rig.source, input);
    try testing.expectEqualStrings("sha256:", first.created.job.input_digest.?[0..7]);
    try testing.expectEqual(@as(?u64, 6), first.created.job.input_bytes);
    const again = try create(&ctx, &rig.source, input);
    try testing.expectEqualStrings("nightly", again.same.name);
    var other = input;
    other.image = "b3:7c02aaaaaaaa";
    try testing.expectError(error.Refused, create(&ctx, &rig.source, other));
    try rig.expect_code(.E0131);
    const view = try get(&ctx, "nightly");
    try testing.expectEqual(records.JobState.pending, state_of(view.status));
    try testing.expectError(error.Refused, get(&ctx, "nope"));
    try rig.expect_code(.E0133);
}

test "a 64 KiB input of control characters is accepted; one more byte is ZC-E0130" {
    // Goal: the owner's decision (job-input-wire-size): every input within job_input_bytes_max is
    // stored, however it is escaped. Method: the worst case, 0x01 repeated.
    var rig: Rig = undefined;
    try rig.start();
    defer rig.stop();
    const ctx = rig.context();
    const bytes = try ctx.arena.alloc(u8, constants.job_input_bytes_max + 1);
    @memset(bytes, 1);
    var input = sample("big");
    input.input = bytes[0..constants.job_input_bytes_max];
    input.input_env = "PAYLOAD";
    const made = try create(&ctx, &rig.source, input);
    const stored_bytes = made.created.job.input_bytes;
    try testing.expectEqual(@as(?u64, constants.job_input_bytes_max), stored_bytes);
    const input_key = records.job_input_key("big");
    const stored = try ctx.store.get(ctx.arena, input_key.slice(), null, &rig.diag);
    try testing.expect(stored.kv != null);
    var over = sample("bigger");
    over.input = bytes;
    over.input_env = "PAYLOAD";
    try testing.expectError(error.Refused, create(&ctx, &rig.source, over));
    try rig.expect_code(.E0130);
}

test "a run record over 16 KiB escaped is ZC-E0130 naming the field, never ZC-B0005" {
    var rig: Rig = undefined;
    try rig.start();
    defer rig.stop();
    const ctx = rig.context();
    const bytes = try ctx.arena.alloc(u8, 4000);
    @memset(bytes, 1);
    var input = sample("wide");
    input.env = &.{.{ "A", bytes }};
    try testing.expectError(error.Refused, create(&ctx, &rig.source, input));
    try rig.expect_code(.E0130);
}

test "limits outside the runtime's bounds are refused, naming the field" {
    var rig: Rig = undefined;
    try rig.start();
    defer rig.stop();
    const ctx = rig.context();
    const bad_limits = [_]records.JobLimits{
        .{ .cpu_millis = 0 },
        .{ .cpu_millis = constants.job_limit_cpu_millis_max + 1 },
        .{ .memory_bytes = 0 },
        .{ .memory_bytes = constants.job_limit_memory_bytes_max + 1 },
        .{ .pids = 0 },
        .{ .pids = constants.job_limit_pids_max + 1 },
    };
    for (bad_limits) |limits| {
        var bad = sample("ok");
        bad.limits = limits;
        try testing.expectError(error.Refused, create(&ctx, &rig.source, bad));
        try rig.expect_code(.E0130);
    }
    var good = sample("ok");
    good.limits = .{
        .cpu_millis = constants.job_limit_cpu_millis_min,
        .memory_bytes = constants.job_limit_memory_bytes_max,
        .pids = constants.job_limit_pids_max,
    };
    _ = try create(&ctx, &rig.source, good);
}

test "validation names the field" {
    var rig: Rig = undefined;
    try rig.start();
    defer rig.stop();
    const ctx = rig.context();
    var bad = sample("Bad");
    try testing.expectError(error.Refused, create(&ctx, &rig.source, bad));
    try rig.expect_code(.E0130);
    bad = sample("ok");
    bad.labels = &.{.{ "zcube.job", "x" }};
    try testing.expectError(error.Refused, create(&ctx, &rig.source, bad));
    try rig.expect_code(.E0130);
    bad = sample("ok");
    bad.input_env = "X";
    try testing.expectError(error.Refused, create(&ctx, &rig.source, bad));
    try rig.expect_code(.E0130);
    // What the runtime would refuse at the start is refused here: the input takes a variable.
    var env: [constants.runtime_env_count_max][2][]const u8 = undefined;
    var names: [constants.runtime_env_count_max][8]u8 = undefined;
    for (&env, &names, 0..) |*pair, *name, index| {
        pair.* = .{ std.fmt.bufPrint(name, "V{d}", .{index}) catch unreachable, "x" }; // 8 bytes.
    }
    bad = sample("ok");
    bad.env = &env;
    bad.input = "hello";
    bad.input_env = "INPUT";
    try testing.expectError(error.Refused, create(&ctx, &rig.source, bad));
    try rig.expect_code(.E0130);
    bad = sample("ok");
    bad.labels = &.{.{ "a=b", "x" }};
    try testing.expectError(error.Refused, create(&ctx, &rig.source, bad));
    try rig.expect_code(.E0130);
    bad = sample("ok");
    bad.deadline_ms = constants.job_deadline_ms_max + 1;
    try testing.expectError(error.Refused, create(&ctx, &rig.source, bad));
    try rig.expect_code(.E0130);
    bad = sample("ok");
    bad.submit_by_ms = now_start + constants.job_submit_window_ms_max + 1;
    try testing.expectError(error.Refused, create(&ctx, &rig.source, bad));
    try rig.expect_code(.E0130);
    bad = sample("ok");
    bad.submit_by_ms = now_start + constants.job_submit_window_ms_max;
    _ = try create(&ctx, &rig.source, bad);
    bad = sample("late");
    bad.submit_by_ms = now_start - 1;
    try testing.expectError(error.Refused, create(&ctx, &rig.source, bad));
    try rig.expect_code(.E0134);
    try testing.expect(variable_name_valid("A_1"));
    try testing.expect(!variable_name_valid(""));
    var long: [constants.job_input_env_bytes_max + 1]u8 = undefined;
    @memset(&long, 'A');
    try testing.expect(variable_name_valid(long[0..constants.job_input_env_bytes_max]));
    try testing.expect(!variable_name_valid(&long));
}

test "jobs_max bounds the jobs in flight; a cancel records itself once" {
    var rig: Rig = undefined;
    try rig.start();
    defer rig.stop();
    const ctx = rig.context();
    var names: [constants.jobs_max + 1][8]u8 = undefined;
    for (&names, 0..) |*name, index| {
        _ = std.fmt.bufPrint(name, "j{d:0>5}", .{index}) catch unreachable; // 6 of 8 bytes.
    }
    for (names[0..constants.jobs_max]) |*name| {
        _ = try create(&ctx, &rig.source, sample(name[0..6]));
    }
    const extra = sample(names[constants.jobs_max][0..6]);
    try testing.expectError(error.Refused, create(&ctx, &rig.source, extra));
    try rig.expect_code(.E0132);
    const first = try cancel(&ctx, &rig.source, "j00000", "alex", "r-1");
    try testing.expect(first == .accepted);
    const second = try cancel(&ctx, &rig.source, "j00000", "alex", "r-2");
    try testing.expect(second == .already);
    try testing.expectError(error.Refused, cancel(&ctx, &rig.source, "zzz", "alex", "r-3"));
    try rig.expect_code(.E0133);
}

test "list filters by label and pages" {
    var rig: Rig = undefined;
    try rig.start();
    defer rig.stop();
    const ctx = rig.context();
    var a = sample("alpha");
    a.labels = &.{.{ "team", "x" }};
    _ = try create(&ctx, &rig.source, a);
    _ = try create(&ctx, &rig.source, sample("beta"));
    const all = try list(&ctx, .{ .limit = 10 });
    try testing.expectEqual(@as(usize, 2), all.rows.len);
    const some = try list(&ctx, .{ .limit = 10, .label = "team=x" });
    try testing.expectEqual(@as(usize, 1), some.rows.len);
    try testing.expectEqualStrings("alpha", some.rows[0].name);
    const none = try list(&ctx, .{ .limit = 10, .state = .running });
    try testing.expectEqual(@as(usize, 0), none.rows.len);
}

// ---- Follow-up tests (review of PR 106) ------------------------------------------------------

/// Writes `/job-status/<name>` as the job controller would.
fn put_status(rig: *Rig, name: []const u8, state: records.JobState) !void {
    const ctx = rig.context();
    const terminal = records.job_state_terminal(state);
    const status: records.JobStatus = .{
        .state = state,
        .ended_at_ms = if (terminal) now_start else null,
        .end = if (terminal) .{ .kind = .exited, .code = 0 } else null,
        .reported_at_ms = now_start,
    };
    var batch: controller.Batch = .{};
    const key = records.job_status_key(name);
    batch.put(try controller.key_copy(&ctx, &key), try records.encode(ctx.arena, status, ctx.diag));
    _ = try controller.commit(&ctx, .job_controller, &batch);
}

fn put_admission(rig: *Rig, admission: records.JobAdmission) !void {
    const ctx = rig.context();
    var batch: controller.Batch = .{};
    batch.put(records.key_job_admission, try records.encode(ctx.arena, admission, ctx.diag));
    _ = try controller.commit(&ctx, .api, &batch);
}

test "a list row carries ended_at_ms of an ended job, and none for a job that has not ended" {
    // Goal: the additive row member that completes the dedupe key (docs/api.md). Method: one
    // job ended by a status put, one without a status; the first row has the status's
    // `ended_at_ms`, the second none; reading again later gives the same value (set once).
    var rig: Rig = undefined;
    try rig.start();
    defer rig.stop();
    const ctx = rig.context();
    _ = try create(&ctx, &rig.source, sample("done"));
    _ = try create(&ctx, &rig.source, sample("waiting"));
    try put_status(&rig, "done", .exited);
    for (0..2) |_| {
        const listing = try list(&ctx, .{ .limit = 10, .ended = false });
        try testing.expectEqual(@as(usize, 2), listing.rows.len);
        try testing.expectEqualStrings("done", listing.rows[0].name);
        try testing.expectEqual(@as(?u64, now_start), listing.rows[0].ended_at_ms);
        try testing.expectEqual(@as(?u64, null), listing.rows[1].ended_at_ms);
    }
}

test "cancel of an ended job changes nothing and reports the revision the status was read at" {
    var rig: Rig = undefined;
    try rig.start();
    defer rig.stop();
    const ctx = rig.context();
    _ = try create(&ctx, &rig.source, sample("done"));
    try put_status(&rig, "done", .exited);
    const status_revision = (try ctx.store.status(ctx.diag)).revision;
    const result = try cancel(&ctx, &rig.source, "done", "alex", "r-9");
    try testing.expect(result == .finished);
    try testing.expectEqual(status_revision, result.finished.revision);
    try testing.expectEqual(records.JobState.exited, state_of(result.finished.status));
    try testing.expectEqual(records.JobState.exited, try current_state(&ctx, "done"));
    const again = try create(&ctx, &rig.source, sample("done"));
    try testing.expect(again == .same);
    const view = try get(&ctx, "done");
    try testing.expect(view.job.cancel_requested == null);
}

/// Runs `after_status` once, after the store answered its next `status` call: a write that lands
/// between the reads of a request and its commit. State is global because the memory store's
/// context is its own.
const Race = struct {
    var rig: *Rig = undefined;
    var armed: bool = false;
    var original: *const store.Store.VTable = undefined;

    fn status(context: *anyopaque, diag: *Diag) store.Error!store.Status {
        const answer = try original.status(context, diag);
        if (armed) {
            armed = false;
            put_status(rig, "racing", .exited) catch @panic("race: status write failed");
        }
        return answer;
    }
};

test "a cancel does not commit over a status that changed after it was read" {
    var rig: Rig = undefined;
    try rig.start();
    defer rig.stop();
    var ctx = rig.context();
    _ = try create(&ctx, &rig.source, sample("racing"));
    var vtable = rig.memory.interface().vtable.*;
    Race.original = rig.memory.interface().vtable;
    Race.rig = &rig;
    vtable.status = Race.status;
    ctx.store = .{ .context = rig.memory.interface().context, .vtable = &vtable };
    Race.armed = true;
    const result = try cancel(&ctx, &rig.source, "racing", "alex", "r-1");
    try testing.expect(result == .conflict);
    const view = try get(&rig.context(), "racing");
    try testing.expect(view.job.cancel_requested == null);
    // A retry sees the ending and reports it.
    const retry = try cancel(&rig.context(), &rig.source, "racing", "alex", "r-2");
    try testing.expect(retry == .finished);
}

test "the admission window drops old hours and relabels hours ahead of a clock that went back" {
    var rig: Rig = undefined;
    try rig.start();
    defer rig.stop();
    const ctx = rig.context();
    const hour = now_start / hour_ms;
    try put_admission(&rig, .{
        .admitted = constants.job_admitted_window_max,
        .hours = &.{.{ .hour = hour - 1, .count = constants.job_admitted_window_max }},
    });
    var ended: controller.Batch = .{};
    const endings: records.JobEndings = .{ .ended = constants.job_admitted_window_max };
    ended.put(records.key_job_endings, try records.encode(ctx.arena, endings, ctx.diag));
    _ = try controller.commit(&ctx, .job_controller, &ended);
    try testing.expectError(error.Refused, create(&ctx, &rig.source, sample("full")));
    try rig.expect_code(.E0132);
    // The hour rolls out of the window: one create fits, and the old hour is gone.
    rig.manual.advance(@as(u64, constants.job_admission_window_h) * hour_ms);
    var input = sample("rolled");
    input.submit_by_ms = rig.manual.ms + 30_000;
    _ = try create(&ctx, &rig.source, input);
    const kv = (try ctx.store.get(ctx.arena, records.key_job_admission, null, ctx.diag)).kv.?;
    const now = try records.read(records.JobAdmission, ctx.arena, kv, ctx.diag);
    try testing.expectEqual(@as(usize, 1), now.hours.len);
    try testing.expectEqual(@as(u32, 1), now.hours[0].count);
    // The clock goes back an hour: the bucket ahead of it is relabelled as the current hour with
    // its count (#180), so the create makes a bucket of two for the hour the clock shows.
    rig.manual.ms -= hour_ms;
    var back = sample("back");
    back.submit_by_ms = rig.manual.ms + 30_000;
    _ = try create(&ctx, &rig.source, back);
    const kv2 = (try ctx.store.get(ctx.arena, records.key_job_admission, null, ctx.diag)).kv.?;
    const folded = try records.read(records.JobAdmission, ctx.arena, kv2, ctx.diag);
    try testing.expectEqual(@as(usize, 1), folded.hours.len);
    try testing.expectEqual(@as(u32, 2), folded.hours[0].count);
    try testing.expectEqual(rig.manual.ms / hour_ms, folded.hours[0].hour);
}

test "a late retry of a job that exists answers with it; a missing job is ZC-E0134" {
    // Goal: Decisions 2 of the b2 brief (RB-S4): `submit_by_ms` having passed refuses only a job
    // that does not exist. Method: create, pass the time, send the same spec, then a different
    // one (ZC-E0131 still), then a new name (ZC-E0134).
    var rig: Rig = undefined;
    try rig.start();
    defer rig.stop();
    const ctx = rig.context();
    const input = sample("nightly");
    _ = try create(&ctx, &rig.source, input);
    rig.manual.advance(31_000);
    try testing.expect(rig.manual.ms > input.submit_by_ms);
    const again = try create(&ctx, &rig.source, input);
    try testing.expectEqualStrings("nightly", again.same.name);
    var other = input;
    other.image = "b3:7c02aaaaaaaa";
    try testing.expectError(error.Refused, create(&ctx, &rig.source, other));
    try rig.expect_code(.E0131);
    try testing.expectError(error.Refused, create(&ctx, &rig.source, sample("missing")));
    try rig.expect_code(.E0134);
}

test "env and labels compare as maps, and a duplicate label is refused" {
    // Goal: Decisions 2 (RB-S9): a retry that lists env or labels in another order is the same
    // job; a duplicate key is ZC-E0130, for labels as env already was.
    var rig: Rig = undefined;
    try rig.start();
    defer rig.stop();
    const ctx = rig.context();
    var input = sample("ordered");
    input.env = &.{ .{ "A", "1" }, .{ "B", "2" } };
    input.labels = &.{ .{ "x", "1" }, .{ "y", "2" } };
    _ = try create(&ctx, &rig.source, input);
    var swapped = input;
    swapped.env = &.{ .{ "B", "2" }, .{ "A", "1" } };
    swapped.labels = &.{ .{ "y", "2" }, .{ "x", "1" } };
    try testing.expect((try create(&ctx, &rig.source, swapped)) == .same);
    var changed = swapped;
    changed.labels = &.{ .{ "y", "2" }, .{ "x", "3" } };
    try testing.expectError(error.Refused, create(&ctx, &rig.source, changed));
    try rig.expect_code(.E0131);
    var twice = sample("twice");
    twice.labels = &.{ .{ "x", "1" }, .{ "x", "2" } };
    try testing.expectError(error.Refused, create(&ctx, &rig.source, twice));
    try rig.expect_code(.E0130);
}

test "a job stored before #178 is still found by its retry, whatever its keys and limits" {
    // Goal: #180. A job stored before the bounds and the duplicate-key checks may carry both.
    // Method: create a job, rewrite its record with a cpu limit under the minimum and a repeated
    // env pair, pass the submit time, then send the same spec (the original answer), a spec with
    // another env value and the same limits (refused for its limits, ZC-E0130, as any new job)
    // and the same limits on a missing name (ZC-E0130).
    var rig: Rig = undefined;
    try rig.start();
    defer rig.stop();
    const ctx = rig.context();
    var input = sample("legacy");
    input.env = &.{.{ "A", "1" }};
    _ = try create(&ctx, &rig.source, input);
    const key = records.job_key("legacy");
    const kv = (try ctx.store.get(ctx.arena, key.slice(), null, ctx.diag)).kv.?;
    var stored = try records.read(records.Job, ctx.arena, kv, ctx.diag);
    stored.limits = .{ .cpu_millis = constants.job_limit_cpu_millis_min - 1 };
    stored.env = &.{ .{ "A", "1" }, .{ "A", "1" } };
    var batch: controller.Batch = .{};
    batch.put(key.slice(), try records.encode(ctx.arena, stored, ctx.diag));
    _ = try controller.commit(&ctx, .api, &batch);
    rig.manual.advance(31_000);
    var retry = input;
    retry.limits = stored.limits;
    const again = try create(&ctx, &rig.source, retry);
    try testing.expectEqualStrings("legacy", again.same.name);
    var other = retry;
    other.env = &.{.{ "A", "2" }};
    try testing.expectError(error.Refused, create(&ctx, &rig.source, other));
    try rig.expect_code(.E0130);
    var fresh = retry;
    fresh.name = "fresh";
    try testing.expectError(error.Refused, create(&ctx, &rig.source, fresh));
    try rig.expect_code(.E0130);
}

test "pairs compare as sets: a repeated pair is one pair, a key with two values is not" {
    const one = [_]records.Pair{.{ "A", "1" }};
    const twice = [_]records.Pair{ .{ "A", "1" }, .{ "A", "1" } };
    const split = [_]records.Pair{ .{ "A", "1" }, .{ "A", "2" } };
    try testing.expect(pairs_equal(&twice, &one));
    try testing.expect(pairs_equal(&one, &twice));
    try testing.expect(!pairs_equal(&split, &one));
    try testing.expect(!pairs_equal(&one, &split));
    try testing.expect(pairs_equal(&.{}, &.{}));
}

test "a run record of exactly job_run_bytes_max is accepted and one byte more is refused" {
    var rig: Rig = undefined;
    try rig.start();
    defer rig.stop();
    const ctx = rig.context();
    const pad = try ctx.arena.alloc(u8, constants.job_run_bytes_max + 1);
    @memset(pad, 'a');
    var job = sample("sized");
    job.command = &.{pad[0..1]};
    const small = try measured(&ctx, job);
    const fit = 1 + (constants.job_run_bytes_max - small);
    job.command = &.{pad[0..fit]};
    try testing.expectEqual(@as(usize, constants.job_run_bytes_max), try measured(&ctx, job));
    _ = try create(&ctx, &rig.source, job);
    var over = sample("sized-over");
    over.command = &.{pad[0 .. fit + 1]};
    try testing.expectError(error.Refused, create(&ctx, &rig.source, over));
    try rig.expect_code(.E0130);
}

/// The size `check_run_size` measures for `input`, with the id the run would get.
fn measured(ctx: *const Context, input: Input) !usize {
    const job: records.Job = .{
        .name = input.name,
        .image = input.image,
        .command = input.command,
        .deadline_ms = input.deadline_ms,
        .submit_by_ms = input.submit_by_ms,
        .created_at_ms = now_start,
        .applied_by = input.applied_by,
    };
    var id_buffer: [constants.job_run_id_bytes_max]u8 = undefined;
    return json_bytes(ctx, run_of(&job, records.job_run_id(&id_buffer, job.name)));
}
