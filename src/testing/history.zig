//! The history recorder and checker for the store fault tests (core: no threads, files, sockets or
//! clock; `std.atomic` and an allocator only, so it stays `wasm32-freestanding`-clean).
//!
//! A test drives a `Store` from several client threads. Each thread owns a `Recorder` and writes
//! down every call before it makes it (`invoke`) and what came back (`ack_txn`, `ack_read`, `fail`
//! or `unknown`). Calls are ordered by one shared `Ticker`, so "A returned before B was invoked"
//! is a comparison of two numbers and no lock is held around a store call. After the run (and
//! after healing the network) the test reads the whole log back from a direct connection and
//! hands history and log to `check`.
//!
//! ## What the recorded calls look like
//!
//! Keys are small ids and values are unique tokens (`value_text`), so every write can be found in
//! the log by what it wrote. Two kinds of key keep the model small:
//!
//! - A register key (id below `audit_key_min`) is written by `compare mod_revision == e, put
//!   key` (compare-and-set) or by a blind put, and read by `get`. A register write puts only its
//!   own key: the compare key (if any) and every success put name one register key, and every
//!   failure put is an audit key. A write that breaks this is `bad_history`, never guessed at.
//! - An audit key (id from `audit_key_min`) is written only by the `on_failure` branch of a
//!   compare-and-set (a put of a fresh token, so a failed compare leaves a trace in the log). It
//!   is never compared or read.
//!
//! ## What `check` verifies
//!
//! 0. Every value token is unique across the history (`bad_history`): a token is how a write is
//!    found in the log, so a repeated one makes every later verdict misleading.
//! 1. The log is gap-free and in commit order: it starts at `base_revision + 1`, a revision's
//!    events are together, revisions rise by exactly one and the last is `final_revision`
//!    (`log_gap`, `log_disorder`), and no value token appears twice (`duplicate_value`).
//! 2. Every write the store acknowledged is in the log at the revision it was given, with the
//!    events its writer sent and no others (`lost_write`, `event_mismatch`); no two writes were
//!    given one revision (`revision_reused`); and no event is nobody's (`unexplained_event`).
//! 3. A write reported as failed with nothing changed is absent from the log (`failed_in_log`).
//! 4. A write whose outcome is unknown (the connection dropped during COMMIT, or the call never
//!    returned) is wholly in the log, as exactly its success branch or exactly its failure
//!    branch, or wholly absent (`unknown_partial`). One that is in is then treated as a write
//!    that never returned: it may take effect at any point after it was invoked.
//! 5. Revisions follow real time across keys: when one write that created a revision returned
//!    before another was invoked, it has the lower revision (`revision_order`).
//! 6. Per register key, the acknowledged calls are linearizable (`not_linearizable`): there is
//!    one order, consistent with real time, in which a sequential register gives every result.
//!    The search is Wing and Gong's, depth first over the calls no pending call precedes. It is
//!    bounded: at most `key_calls_max` calls on a key and `search_steps_max` steps, and a search
//!    that runs out of either is `search_exhausted` or `bad_history` and fails the check; it never
//!    passes a history it did not decide.
//! 7. `check_watch`: a watch opened at N + 1 delivered exactly the log after N, up to the
//!    revision its last batch reported (`watch_mismatch`); a watch that opened at or before the
//!    log's base, or reported a revision beyond its end, is `bad_history`.

const std = @import("std");
const assert = std.debug.assert;

const Allocator = std.mem.Allocator;

pub const never = std.math.maxInt(u64);
pub const audit_key_min = 128;
pub const key_calls_max = 64;
pub const search_steps_max = 2_000_000;

/// Orders the invocations and completions of all clients. It counts in 32 bits because
/// `wasm32` has no wider atomics; a run makes far fewer calls than that.
pub const Ticker = struct {
    next: std.atomic.Value(u32) = .init(1),

    pub fn tick(ticker: *Ticker) u64 {
        const number = ticker.next.fetchAdd(1, .acq_rel);
        assert(number != std.math.maxInt(u32)); // The count must never wrap.
        return number;
    }
};

pub const Put = struct {
    key: u8,
    value: u64,
};

pub const Compare = struct {
    key: u8,
    mod_revision: u64,
};

pub const Txn = struct {
    compare: ?Compare,
    success: []const Put,
    failure: []const Put,
};

pub const Call = union(enum) {
    txn: Txn,
    read: u8,
};

pub const Outcome = enum {
    /// The store answered. For a transaction `succeeded` and `revision` say what it answered.
    acked,
    /// The store said, definitely, that nothing was changed.
    failed,
    /// The answer was lost, or never came.
    unknown,
};

pub const Entry = struct {
    client: u32,
    invoke: u64,
    complete: u64,
    call: Call,
    outcome: Outcome,
    succeeded: bool,
    /// A transaction's revision after it; a read's `mod_revision` of the key (0: absent).
    revision: u64,
    /// A read: the value token found.
    value: u64,
};

pub const Recorder = struct {
    gpa: Allocator,
    client: u32,
    entries: std.ArrayList(Entry),

    pub fn init(gpa: Allocator, client: u32) Recorder {
        return .{ .gpa = gpa, .client = client, .entries = .empty };
    }

    pub fn deinit(recorder: *Recorder) void {
        for (recorder.entries.items) |entry| switch (entry.call) {
            .txn => |txn| {
                recorder.gpa.free(txn.success);
                recorder.gpa.free(txn.failure);
            },
            .read => {},
        };
        recorder.entries.deinit(recorder.gpa);
    }

    /// Writes the call down before it is made; the handle goes to the matching completion.
    /// Until then the entry is an unknown that never returned.
    pub fn invoke(recorder: *Recorder, ticker: *Ticker, call: Call) !usize {
        var own = call;
        if (call == .txn) {
            const success = try recorder.gpa.dupe(Put, call.txn.success);
            errdefer recorder.gpa.free(success);
            own.txn.success = success;
            own.txn.failure = try recorder.gpa.dupe(Put, call.txn.failure);
        }
        try recorder.entries.append(recorder.gpa, .{
            .client = recorder.client,
            .invoke = ticker.tick(),
            .complete = never,
            .call = own,
            .outcome = .unknown,
            .succeeded = false,
            .revision = 0,
            .value = 0,
        });
        return recorder.entries.items.len - 1;
    }

    pub fn ack_txn(recorder: *Recorder, ticker: *Ticker, handle: usize, result: TxnAck) void {
        const entry = &recorder.entries.items[handle];
        assert(entry.call == .txn);
        entry.outcome = .acked;
        entry.succeeded = result.succeeded;
        entry.revision = result.revision;
        entry.complete = ticker.tick();
    }

    pub fn ack_read(recorder: *Recorder, ticker: *Ticker, handle: usize, found: ReadAck) void {
        const entry = &recorder.entries.items[handle];
        assert(entry.call == .read);
        entry.outcome = .acked;
        entry.revision = found.mod_revision;
        entry.value = found.value;
        entry.complete = ticker.tick();
    }

    /// The call failed and said nothing was changed.
    pub fn fail(recorder: *Recorder, ticker: *Ticker, handle: usize) void {
        const entry = &recorder.entries.items[handle];
        entry.outcome = .failed;
        entry.complete = ticker.tick();
    }

    /// The call failed and the write may or may not have been applied. It stays open-ended in
    /// real time: it may take effect at any later point.
    pub fn unknown(recorder: *Recorder, handle: usize) void {
        recorder.entries.items[handle].outcome = .unknown;
    }
};

pub const TxnAck = struct { succeeded: bool, revision: u64 };
pub const ReadAck = struct { mod_revision: u64, value: u64 };

/// All the clients' entries in one list. The puts stay owned by the recorders.
pub fn merge(gpa: Allocator, recorders: []const *const Recorder) ![]Entry {
    var all: std.ArrayList(Entry) = .empty;
    errdefer all.deinit(gpa);
    for (recorders) |recorder| try all.appendSlice(gpa, recorder.entries.items);
    return all.toOwnedSlice(gpa);
}

// ---- Names --------------------------------------------------------------------------------------

/// "/h/k" and the id as two hex digits. Register ids stay below `audit_key_min`.
pub fn key_text(buffer: *[8]u8, id: u8) []const u8 {
    // Five bytes fit in eight.
    return std.fmt.bufPrint(buffer, "/h/k{x:0>2}", .{id}) catch unreachable; // Cannot overflow.
}

pub fn parse_key(text: []const u8) ?u8 {
    if (text.len != 6 or !std.mem.startsWith(u8, text, "/h/k")) return null;
    return std.fmt.parseInt(u8, text[4..], 16) catch null;
}

/// "v" and the token in decimal.
pub fn value_text(buffer: *[24]u8, token: u64) []const u8 {
    // At most 21 bytes fit in 24.
    return std.fmt.bufPrint(buffer, "v{d}", .{token}) catch unreachable; // Cannot overflow.
}

pub fn parse_value(text: []const u8) ?u64 {
    if (text.len < 2 or text[0] != 'v') return null;
    return std.fmt.parseInt(u64, text[1..], 10) catch null;
}

// ---- The log ------------------------------------------------------------------------------------

pub const EventKind = enum { put, delete };

/// One event of the store's log, in the checker's terms.
pub const LogEvent = struct {
    revision: u64,
    kind: EventKind,
    key: u8,
    value: u64,
};

pub const Options = struct {
    /// The log is every event after this revision.
    base_revision: u64 = 0,
    /// The store's revision when the log was read.
    final_revision: u64,
};

pub const Kind = enum {
    log_gap,
    log_disorder,
    duplicate_value,
    lost_write,
    event_mismatch,
    revision_reused,
    unexplained_event,
    revision_order,
    failed_in_log,
    unknown_partial,
    not_linearizable,
    search_exhausted,
    bad_history,
    watch_mismatch,
};

/// What went wrong and where: a revision, a register key or an entry index, as the kind says.
pub const Failure = struct {
    kind: Kind,
    revision: u64 = 0,
    key: u8 = 0,
    entry: u32 = 0,
};

const Detail = struct {
    revision: u64 = 0,
    key: u8 = 0,
};

pub const Verdict = union(enum) {
    ok,
    failed: Failure,
};

fn failure(kind: Kind, detail: Detail) Verdict {
    return .{ .failed = .{ .kind = kind, .revision = detail.revision, .key = detail.key } };
}

/// The checks of the header, in that order; the first that fails is the verdict.
pub fn check(
    gpa: Allocator,
    history: []const Entry,
    log: []const LogEvent,
    options: Options,
) !Verdict {
    if (try check_unique_tokens(gpa, history)) |bad| return .{ .failed = bad };
    if (check_log_order(log, options)) |bad| return .{ .failed = bad };
    var tokens: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer tokens.deinit(gpa);
    for (log, 0..) |event, index| {
        if (event.kind != .put) continue;
        const slot = try tokens.getOrPut(gpa, event.value);
        if (slot.found_existing) return failure(.duplicate_value, .{ .revision = event.revision });
        slot.value_ptr.* = @intCast(index);
    }
    const claimed = try gpa.alloc(bool, log.len);
    defer gpa.free(claimed);
    @memset(claimed, false);
    const resolved = try gpa.alloc(Resolved, history.len);
    defer gpa.free(resolved);
    const context: Context = .{
        .log = log,
        .tokens = &tokens,
        .claimed = claimed,
        .final = options.final_revision,
    };
    if (try context.account(history, resolved)) |bad| return .{ .failed = bad };
    for (claimed, 0..) |was, index| {
        if (!was) return failure(.unexplained_event, .{ .revision = log[index].revision });
    }
    if (check_revision_order(history, resolved)) |bad| return .{ .failed = bad };
    return check_registers(history, resolved);
}

/// No value token is put by two calls, or twice by one.
fn check_unique_tokens(gpa: Allocator, history: []const Entry) !?Failure {
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(gpa);
    for (history, 0..) |entry, index| {
        if (entry.call != .txn) continue;
        const txn = entry.call.txn;
        for ([_][]const Put{ txn.success, txn.failure }) |puts| {
            for (puts) |put| {
                const slot = try seen.getOrPut(gpa, put.value);
                if (slot.found_existing) return .{ .kind = .bad_history, .entry = @intCast(index) };
            }
        }
    }
    return null;
}

/// The puts of the branch that took effect; empty for a read or a write that did not apply.
fn applied_puts(entry: Entry, how: Resolved) []const Put {
    if (entry.call != .txn or !how.applied) return &.{};
    return if (how.succeeded) entry.call.txn.success else entry.call.txn.failure;
}

/// Across all keys: a write that returned before another was invoked has the lower revision. Only
/// writes that made a revision count (a compare-and-set that changed nothing reports the current
/// one). Quadratic in the writes; a run has a few thousand at most.
fn check_revision_order(history: []const Entry, resolved: []const Resolved) ?Failure {
    for (history, resolved) |early, early_how| {
        if (early.outcome != .acked) continue;
        if (applied_puts(early, early_how).len == 0) continue;
        for (history, resolved, 0..) |late, late_how, late_index| {
            if (applied_puts(late, late_how).len == 0) continue;
            if (early.complete >= late.invoke) continue;
            if (early_how.revision < late_how.revision) continue;
            return .{
                .kind = .revision_order,
                .revision = late_how.revision,
                .entry = @intCast(late_index),
            };
        }
    }
    return null;
}

fn check_log_order(log: []const LogEvent, options: Options) ?Failure {
    var previous = options.base_revision;
    for (log) |event| {
        if (event.revision <= options.base_revision or event.revision < previous) {
            return .{ .kind = .log_disorder, .revision = event.revision };
        }
        if (event.revision > previous) {
            if (event.revision != previous + 1) {
                return .{ .kind = .log_gap, .revision = event.revision };
            }
        }
        previous = event.revision;
    }
    if (previous != options.final_revision) return .{ .kind = .log_gap, .revision = previous };
    return null;
}

/// What the log says about one entry: whether it took effect, as a success or a failed compare.
const Resolved = struct {
    applied: bool = false,
    succeeded: bool = false,
    revision: u64 = 0,
};

const Context = struct {
    log: []const LogEvent,
    tokens: *const std.AutoHashMapUnmanaged(u64, u32),
    claimed: []bool,
    final: u64,

    /// Settles every transaction against the log: the acknowledged ones are found, the failed
    /// ones are absent, the unknown ones are in whole or out whole. Fills `resolved`.
    fn account(context: Context, history: []const Entry, resolved: []Resolved) !?Failure {
        for (history, 0..) |entry, index| {
            resolved[index] = .{};
            if (entry.call != .txn) continue;
            const txn = entry.call.txn;
            const bad = switch (entry.outcome) {
                .acked => context.account_acked(entry, &resolved[index]),
                .failed => context.account_failed(txn),
                .unknown => context.account_unknown(txn, &resolved[index]),
            };
            if (bad) |found| {
                var detailed = found;
                detailed.entry = @intCast(index);
                return detailed;
            }
        }
        return null;
    }

    fn account_acked(context: Context, entry: Entry, resolved: *Resolved) ?Failure {
        const txn = entry.call.txn;
        resolved.* = .{ .applied = true, .succeeded = entry.succeeded, .revision = entry.revision };
        const puts = if (entry.succeeded) txn.success else txn.failure;
        if (puts.len == 0) {
            if (entry.revision > context.final) {
                return .{ .kind = .lost_write, .revision = entry.revision };
            }
            return null;
        }
        return context.claim(entry.revision, puts, .event_mismatch);
    }

    fn account_failed(context: Context, txn: Txn) ?Failure {
        for ([_][]const Put{ txn.success, txn.failure }) |puts| {
            for (puts) |put| {
                if (context.tokens.get(put.value)) |at| {
                    return .{ .kind = .failed_in_log, .revision = context.log[at].revision };
                }
            }
        }
        return null;
    }

    /// In whole as one branch, or absent. Both branches present, or a branch in part, is partial.
    fn account_unknown(context: Context, txn: Txn, resolved: *Resolved) ?Failure {
        const in_success = context.first_present(txn.success);
        const in_failure = context.first_present(txn.failure);
        if (in_success != null and in_failure != null) return .{ .kind = .unknown_partial };
        const at = in_success orelse in_failure orelse return null;
        const revision = context.log[at].revision;
        const puts = if (in_success != null) txn.success else txn.failure;
        resolved.* = .{ .applied = true, .succeeded = in_success != null, .revision = revision };
        return context.claim(revision, puts, .unknown_partial);
    }

    fn first_present(context: Context, puts: []const Put) ?u32 {
        for (puts) |put| {
            if (context.tokens.get(put.value)) |at| return at;
        }
        return null;
    }

    /// The events of `revision` are exactly `puts`, and nobody else has them.
    fn claim(context: Context, revision: u64, puts: []const Put, mismatch: Kind) ?Failure {
        const run = context.run_of(revision) orelse {
            return .{ .kind = .lost_write, .revision = revision };
        };
        for (context.claimed[run.lo..run.hi]) |was| {
            if (was) return .{ .kind = .revision_reused, .revision = revision };
        }
        if (run.hi - run.lo != puts.len) return .{ .kind = mismatch, .revision = revision };
        for (puts, context.log[run.lo..run.hi]) |put, event| {
            const same = event.kind == .put and event.key == put.key and event.value == put.value;
            if (!same) return .{ .kind = mismatch, .revision = revision };
        }
        @memset(context.claimed[run.lo..run.hi], true);
        return null;
    }

    const Run = struct { lo: usize, hi: usize };

    /// The events of one revision (the log is sorted by revision, checked before).
    fn run_of(context: Context, revision: u64) ?Run {
        var lo: usize = 0;
        var hi: usize = context.log.len;
        while (lo < hi) {
            const middle = lo + (hi - lo) / 2;
            if (context.log[middle].revision < revision) lo = middle + 1 else hi = middle;
        }
        var end = lo;
        while (end < context.log.len and context.log[end].revision == revision) end += 1;
        if (end == lo) return null;
        return .{ .lo = lo, .hi = end };
    }
};

// ---- Linearizability of one register -----------------------------------------------------------

const Register = struct { revision: u64, value: u64 };

const Step = struct {
    invoke: u64,
    complete: u64,
    action: union(enum) {
        /// `expect` is null for a blind put. `succeeded` is what the store answered.
        write: struct { expect: ?u64, succeeded: bool, revision: u64, value: u64 },
        read: Register,
    },
};

fn check_registers(history: []const Entry, resolved: []const Resolved) Verdict {
    var keys: [audit_key_min]bool = @splat(false);
    for (history) |entry| {
        const found = register_key(entry) catch return failure(.bad_history, .{});
        const key = found orelse continue;
        if (key >= audit_key_min) return failure(.bad_history, .{ .key = key });
        keys[key] = true;
    }
    var steps: [key_calls_max]Step = undefined;
    for (keys, 0..) |present, key| {
        if (!present) continue;
        var count: usize = 0;
        for (history, resolved) |entry, how| {
            const found = register_key(entry) catch unreachable; // Checked above.
            if (found != @as(u8, @intCast(key))) continue;
            const made = step_of(entry, how) catch {
                return failure(.bad_history, .{ .key = @intCast(key) });
            };
            const step = made orelse continue;
            if (count == steps.len) return failure(.bad_history, .{ .key = @intCast(key) });
            steps[count] = step;
            count += 1;
        }
        switch (search(steps[0..count])) {
            .linearizable => {},
            .violation => return failure(.not_linearizable, .{ .key = @intCast(key) }),
            .exhausted => return failure(.search_exhausted, .{ .key = @intCast(key) }),
        }
    }
    return .ok;
}

const BadHistory = error{BadHistory};

/// The register a call is about; null for a write to nothing a register model covers. A register
/// write puts only its own key (see the header): a compare on another key, success puts on
/// several keys, or a failure put on a register key is `BadHistory`.
fn register_key(entry: Entry) BadHistory!?u8 {
    switch (entry.call) {
        .read => |key| return key,
        .txn => |txn| {
            for (txn.failure) |put| {
                if (put.key < audit_key_min) return error.BadHistory;
            }
            const own: ?u8 = if (txn.compare) |compare| compare.key else null;
            if (txn.success.len == 0) return own;
            const key = txn.success[0].key;
            for (txn.success) |put| {
                if (put.key != key) return error.BadHistory;
            }
            if (own != null and own.? != key) return error.BadHistory;
            return key;
        },
    }
}

fn step_of(entry: Entry, how: Resolved) BadHistory!?Step {
    switch (entry.call) {
        .read => {
            if (entry.outcome != .acked) return null;
            const found: Register = .{ .revision = entry.revision, .value = entry.value };
            return .{
                .invoke = entry.invoke,
                .complete = entry.complete,
                .action = .{ .read = found },
            };
        },
        .txn => |txn| {
            if (!how.applied) return null;
            const expect: ?u64 = if (txn.compare) |compare| compare.mod_revision else null;
            if (how.succeeded and txn.success.len == 0) return error.BadHistory;
            const value = if (how.succeeded) txn.success[txn.success.len - 1].value else 0;
            const complete = if (entry.outcome == .acked) entry.complete else never;
            return .{ .invoke = entry.invoke, .complete = complete, .action = .{ .write = .{
                .expect = expect,
                .succeeded = how.succeeded,
                .revision = how.revision,
                .value = value,
            } } };
        },
    }
}

/// The register after `step`, or null if the step's answer is impossible from `state`.
fn apply(state: Register, step: Step) ?Register {
    switch (step.action) {
        .read => |seen| {
            const same = seen.revision == state.revision and seen.value == state.value;
            return if (same) state else null;
        },
        .write => |put| {
            const holds = if (put.expect) |expected| expected == state.revision else true;
            if (holds != put.succeeded) return null;
            if (!holds) return state;
            if (put.revision <= state.revision) return null; // Revisions only rise.
            return .{ .revision = put.revision, .value = put.value };
        },
    }
}

const Search = enum { linearizable, violation, exhausted };

/// Wing and Gong, depth first with an explicit stack: choose, among the steps not yet placed that
/// no unplaced step finished before (so none is forced earlier), one the register accepts; undo
/// the choice when nothing fits. At most `key_calls_max` steps and `search_steps_max` moves.
fn search(steps: []const Step) Search {
    assert(steps.len <= key_calls_max);
    if (steps.len == 0) return .linearizable;
    const all: u64 = @as(u64, std.math.maxInt(u64)) >> @intCast(64 - steps.len);
    var placed: u64 = 0;
    var depth: usize = 0;
    var states: [key_calls_max + 1]Register = undefined;
    var chosen: [key_calls_max]usize = undefined;
    var cursor: [key_calls_max + 1]usize = undefined;
    states[0] = .{ .revision = 0, .value = 0 };
    cursor[0] = 0;
    for (0..search_steps_max) |_| {
        if (placed == all) return .linearizable;
        if (next_choice(steps, placed, states[depth], cursor[depth])) |choice| {
            cursor[depth] = choice.index + 1;
            chosen[depth] = choice.index;
            placed |= @as(u64, 1) << @intCast(choice.index);
            states[depth + 1] = choice.state;
            cursor[depth + 1] = 0;
            depth += 1;
        } else {
            if (depth == 0) return .violation;
            depth -= 1;
            placed &= ~(@as(u64, 1) << @intCast(chosen[depth]));
        }
    }
    return .exhausted;
}

const Choice = struct { index: usize, state: Register };

fn next_choice(steps: []const Step, placed: u64, state: Register, from: usize) ?Choice {
    for (steps[from..], from..) |step, index| {
        if (placed & (@as(u64, 1) << @intCast(index)) != 0) continue;
        if (precedes_unplaced(steps, placed, step)) continue;
        if (apply(state, step)) |after| return .{ .index = index, .state = after };
    }
    return null;
}

/// Some unplaced step finished before `step` began, so `step` cannot come first.
fn precedes_unplaced(steps: []const Step, placed: u64, step: Step) bool {
    for (steps, 0..) |other, index| {
        if (placed & (@as(u64, 1) << @intCast(index)) != 0) continue;
        if (other.complete < step.invoke) return true;
    }
    return false;
}

// ---- Watches ------------------------------------------------------------------------------------

/// What a watch delivered: opened at `from_revision`, its last batch reported `bookmark`.
pub const WatchRecord = struct {
    from_revision: u64,
    bookmark: u64,
    events: []const LogEvent,
};

/// The watch delivered exactly the log's events from `from_revision` to `bookmark`: none missed,
/// none repeated, none reordered, none invented. `options` are the log's: a watch that opened at
/// or before its base, or reported a revision beyond its end, cannot be judged (`bad_history`).
pub fn check_watch(log: []const LogEvent, watch: WatchRecord, options: Options) Verdict {
    if (watch.from_revision <= options.base_revision) return failure(.bad_history, .{});
    if (watch.bookmark > options.final_revision) return failure(.bad_history, .{});
    var seen: usize = 0;
    for (log) |event| {
        if (event.revision < watch.from_revision or event.revision > watch.bookmark) continue;
        const same = seen < watch.events.len and std.meta.eql(watch.events[seen], event);
        if (!same) return failure(.watch_mismatch, .{ .revision = event.revision });
        seen += 1;
    }
    if (seen != watch.events.len) return failure(.watch_mismatch, .{ .revision = watch.bookmark });
    return .ok;
}

// ---- Tests: the checker has teeth ---------------------------------------------------------------

const testing = std.testing;

fn write(compare: ?Compare, puts: []const Put, failure_puts: []const Put) Call {
    return .{ .txn = .{ .compare = compare, .success = puts, .failure = failure_puts } };
}

fn acked(invoke: u64, complete: u64, call: Call, result: TxnAck) Entry {
    return .{
        .client = 0,
        .invoke = invoke,
        .complete = complete,
        .call = call,
        .outcome = .acked,
        .succeeded = result.succeeded,
        .revision = result.revision,
        .value = 0,
    };
}

fn read_of(invoke: u64, complete: u64, key: u8, found: ReadAck) Entry {
    return .{
        .client = 0,
        .invoke = invoke,
        .complete = complete,
        .call = .{ .read = key },
        .outcome = .acked,
        .succeeded = false,
        .revision = found.mod_revision,
        .value = found.value,
    };
}

fn put_event(revision: u64, key: u8, value: u64) LogEvent {
    return .{ .revision = revision, .kind = .put, .key = key, .value = value };
}

fn verdict_kind(verdict: Verdict) ?Kind {
    return switch (verdict) {
        .ok => null,
        .failed => |found| found.kind,
    };
}

const create_one = write(.{ .key = 0, .mod_revision = 0 }, &.{.{ .key = 0, .value = 1 }}, &.{});
const swap_two = write(.{ .key = 0, .mod_revision = 1 }, &.{.{ .key = 0, .value = 2 }}, &.{});

test "a sound history passes: create, swap, a lost race with its audit trace, a read" {
    const lost = write(
        .{ .key = 0, .mod_revision = 0 },
        &.{.{ .key = 0, .value = 3 }},
        &.{.{ .key = 130, .value = 4 }},
    );
    const history = [_]Entry{
        acked(1, 2, create_one, .{ .succeeded = true, .revision = 1 }),
        acked(3, 4, swap_two, .{ .succeeded = true, .revision = 2 }),
        acked(5, 6, lost, .{ .succeeded = false, .revision = 3 }),
        read_of(7, 8, 0, .{ .mod_revision = 2, .value = 2 }),
    };
    const log = [_]LogEvent{ put_event(1, 0, 1), put_event(2, 0, 2), put_event(3, 130, 4) };
    const verdict = try check(testing.allocator, &history, &log, .{ .final_revision = 3 });
    try testing.expectEqual(@as(?Kind, null), verdict_kind(verdict));
}

test "teeth: a write acknowledged at revision 3 that the log does not have is a lost write" {
    const third = write(.{ .key = 0, .mod_revision = 2 }, &.{.{ .key = 0, .value = 3 }}, &.{});
    const history = [_]Entry{
        acked(1, 2, create_one, .{ .succeeded = true, .revision = 1 }),
        acked(3, 4, swap_two, .{ .succeeded = true, .revision = 2 }),
        acked(5, 6, third, .{ .succeeded = true, .revision = 3 }),
    };
    const log = [_]LogEvent{ put_event(1, 0, 1), put_event(2, 0, 2) };
    const verdict = try check(testing.allocator, &history, &log, .{ .final_revision = 2 });
    try testing.expectEqual(@as(?Kind, .lost_write), verdict_kind(verdict));
}

test "teeth: two writes acknowledged at one revision are a duplicated revision" {
    const other = write(.{ .key = 1, .mod_revision = 0 }, &.{.{ .key = 1, .value = 2 }}, &.{});
    const history = [_]Entry{
        acked(1, 2, create_one, .{ .succeeded = true, .revision = 1 }),
        acked(3, 5, other, .{ .succeeded = true, .revision = 1 }),
    };
    const log = [_]LogEvent{ put_event(1, 0, 1), put_event(2, 1, 2) };
    const verdict = try check(testing.allocator, &history, &log, .{ .final_revision = 2 });
    try testing.expectEqual(@as(?Kind, .revision_reused), verdict_kind(verdict));
}

test "teeth: a log that repeats a revision later, skips one, or repeats a value is caught" {
    const repeat = [_]LogEvent{ put_event(1, 0, 1), put_event(2, 0, 2), put_event(1, 0, 3) };
    const skip = [_]LogEvent{ put_event(1, 0, 1), put_event(3, 0, 2) };
    const twice = [_]LogEvent{ put_event(1, 0, 1), put_event(2, 0, 1) };
    const none: []const Entry = &.{};
    const a = try check(testing.allocator, none, &repeat, .{ .final_revision = 2 });
    const b = try check(testing.allocator, none, &skip, .{ .final_revision = 3 });
    const c = try check(testing.allocator, none, &twice, .{ .final_revision = 2 });
    try testing.expectEqual(@as(?Kind, .log_disorder), verdict_kind(a));
    try testing.expectEqual(@as(?Kind, .log_gap), verdict_kind(b));
    try testing.expectEqual(@as(?Kind, .duplicate_value), verdict_kind(c));
}

test "teeth: a read that misses a write that finished before it began is not linearizable" {
    const history = [_]Entry{
        acked(1, 2, create_one, .{ .succeeded = true, .revision = 1 }),
        read_of(3, 4, 0, .{ .mod_revision = 0, .value = 0 }),
    };
    const log = [_]LogEvent{put_event(1, 0, 1)};
    const verdict = try check(testing.allocator, &history, &log, .{ .final_revision = 1 });
    try testing.expectEqual(@as(?Kind, .not_linearizable), verdict_kind(verdict));
}

test "teeth: two compare-and-sets from one revision that both succeed are not linearizable" {
    const rival = write(.{ .key = 0, .mod_revision = 1 }, &.{.{ .key = 0, .value = 5 }}, &.{});
    const history = [_]Entry{
        acked(1, 2, create_one, .{ .succeeded = true, .revision = 1 }),
        acked(3, 6, swap_two, .{ .succeeded = true, .revision = 2 }),
        acked(4, 7, rival, .{ .succeeded = true, .revision = 3 }),
    };
    const log = [_]LogEvent{ put_event(1, 0, 1), put_event(2, 0, 2), put_event(3, 0, 5) };
    const verdict = try check(testing.allocator, &history, &log, .{ .final_revision = 3 });
    try testing.expectEqual(@as(?Kind, .not_linearizable), verdict_kind(verdict));
}

test "concurrent writes and reads that fit one order pass" {
    // Overlapping calls: the read (5..9) may see the swap (4..8) or not; either is a valid order.
    const first: ReadAck = .{ .mod_revision = 1, .value = 1 };
    const second: ReadAck = .{ .mod_revision = 2, .value = 2 };
    for ([_]ReadAck{ first, second }) |seen| {
        const history = [_]Entry{
            acked(1, 2, create_one, .{ .succeeded = true, .revision = 1 }),
            acked(4, 8, swap_two, .{ .succeeded = true, .revision = 2 }),
            read_of(5, 9, 0, seen),
        };
        const log = [_]LogEvent{ put_event(1, 0, 1), put_event(2, 0, 2) };
        const verdict = try check(testing.allocator, &history, &log, .{ .final_revision = 2 });
        try testing.expectEqual(@as(?Kind, null), verdict_kind(verdict));
    }
}

test "an event nobody sent, a changed value and a failed write that landed are caught" {
    const history = [_]Entry{acked(1, 2, create_one, .{ .succeeded = true, .revision = 1 })};
    const extra = [_]LogEvent{ put_event(1, 0, 1), put_event(2, 0, 9) };
    const changed = [_]LogEvent{put_event(1, 0, 7)};
    const a = try check(testing.allocator, &history, &extra, .{ .final_revision = 2 });
    const b = try check(testing.allocator, &history, &changed, .{ .final_revision = 1 });
    try testing.expectEqual(@as(?Kind, .unexplained_event), verdict_kind(a));
    try testing.expectEqual(@as(?Kind, .event_mismatch), verdict_kind(b));
    var dropped = acked(1, 2, create_one, .{ .succeeded = true, .revision = 1 });
    dropped.outcome = .failed;
    const landed = [_]LogEvent{put_event(1, 0, 1)};
    const c = try check(testing.allocator, &.{dropped}, &landed, .{ .final_revision = 1 });
    try testing.expectEqual(@as(?Kind, .failed_in_log), verdict_kind(c));
}

test "unknown outcomes: wholly in, wholly out, or partial" {
    const pair = write(null, &.{ .{ .key = 0, .value = 5 }, .{ .key = 0, .value = 6 } }, &.{});
    var lost_ack = acked(1, never, pair, .{ .succeeded = false, .revision = 0 });
    lost_ack.outcome = .unknown;
    const history = [_]Entry{lost_ack};
    const whole = [_]LogEvent{ put_event(1, 0, 5), put_event(1, 0, 6) };
    const partial = [_]LogEvent{put_event(1, 0, 5)};
    const a = try check(testing.allocator, &history, &whole, .{ .final_revision = 1 });
    const b = try check(testing.allocator, &history, &.{}, .{ .final_revision = 0 });
    const c = try check(testing.allocator, &history, &partial, .{ .final_revision = 1 });
    try testing.expectEqual(@as(?Kind, null), verdict_kind(a));
    try testing.expectEqual(@as(?Kind, null), verdict_kind(b));
    try testing.expectEqual(@as(?Kind, .unknown_partial), verdict_kind(c));
}

test "a watch from N + 1 must deliver exactly the log after N" {
    const log = [_]LogEvent{ put_event(1, 0, 1), put_event(2, 0, 2), put_event(3, 0, 3) };
    const exact = WatchRecord{ .from_revision = 2, .bookmark = 3, .events = log[1..] };
    const missed = WatchRecord{ .from_revision = 2, .bookmark = 3, .events = log[2..] };
    const twice = [_]LogEvent{ log[1], log[1], log[2] };
    const repeated = WatchRecord{ .from_revision = 2, .bookmark = 3, .events = &twice };
    const options: Options = .{ .final_revision = 3 };
    try testing.expectEqual(@as(?Kind, null), verdict_kind(check_watch(&log, exact, options)));
    const a = verdict_kind(check_watch(&log, missed, options));
    const b = verdict_kind(check_watch(&log, repeated, options));
    try testing.expectEqual(@as(?Kind, .watch_mismatch), a);
    try testing.expectEqual(@as(?Kind, .watch_mismatch), b);
}

test "names round trip, and a recorder keeps what it was told" {
    var key_buffer: [8]u8 = undefined;
    var value_buffer: [24]u8 = undefined;
    try testing.expectEqual(@as(?u8, 130), parse_key(key_text(&key_buffer, 130)));
    try testing.expectEqual(@as(?u64, 77), parse_value(value_text(&value_buffer, 77)));
    var ticker: Ticker = .{};
    var recorder = Recorder.init(testing.allocator, 3);
    defer recorder.deinit();
    const handle = try recorder.invoke(&ticker, create_one);
    try testing.expectEqual(Outcome.unknown, recorder.entries.items[handle].outcome);
    recorder.ack_txn(&ticker, handle, .{ .succeeded = true, .revision = 1 });
    const entry = recorder.entries.items[handle];
    try testing.expect(entry.outcome == .acked and entry.invoke < entry.complete);
    const merged = try merge(testing.allocator, &.{&recorder});
    defer testing.allocator.free(merged);
    try testing.expectEqual(@as(usize, 1), merged.len);
}

test "teeth: revisions must follow real time across keys" {
    // A (key 0) returned at tick 2 with revision 2; B (key 1) began at tick 3 and got revision 1.
    const first = write(.{ .key = 0, .mod_revision = 0 }, &.{.{ .key = 0, .value = 1 }}, &.{});
    const second = write(.{ .key = 1, .mod_revision = 0 }, &.{.{ .key = 1, .value = 2 }}, &.{});
    const history = [_]Entry{
        acked(1, 2, first, .{ .succeeded = true, .revision = 2 }),
        acked(3, 4, second, .{ .succeeded = true, .revision = 1 }),
    };
    const log = [_]LogEvent{ put_event(1, 1, 2), put_event(2, 0, 1) };
    const verdict = try check(testing.allocator, &history, &log, .{ .final_revision = 2 });
    try testing.expectEqual(@as(?Kind, .revision_order), verdict_kind(verdict));
    // Overlapping calls may take either order.
    var overlap = history;
    overlap[1].invoke = 2;
    const fine = try check(testing.allocator, &overlap, &log, .{ .final_revision = 2 });
    try testing.expectEqual(@as(?Kind, null), verdict_kind(fine));
}

test "teeth: a register write that puts another key, or several, is a bad history" {
    const moved = write(.{ .key = 0, .mod_revision = 0 }, &.{.{ .key = 1, .value = 1 }}, &.{});
    const blind = write(null, &.{ .{ .key = 0, .value = 2 }, .{ .key = 1, .value = 3 } }, &.{});
    const on_register = write(null, &.{.{ .key = 0, .value = 4 }}, &.{.{ .key = 1, .value = 5 }});
    const calls = [_]Call{ moved, blind, on_register };
    for (calls, 0..) |call, index| {
        const history = [_]Entry{acked(1, 2, call, .{ .succeeded = true, .revision = 1 })};
        const puts = call.txn.success;
        var events: [2]LogEvent = undefined;
        for (puts, 0..) |put, at| events[at] = put_event(1, put.key, put.value);
        const verdict = try check(testing.allocator, &history, events[0..puts.len], .{
            .final_revision = 1,
        });
        errdefer std.debug.print("call {d}\n", .{index});
        try testing.expectEqual(@as(?Kind, .bad_history), verdict_kind(verdict));
    }
}

test "teeth: a successful compare-and-set with an empty success branch is a bad history" {
    const empty = write(.{ .key = 0, .mod_revision = 0 }, &.{}, &.{});
    const history = [_]Entry{acked(1, 2, empty, .{ .succeeded = true, .revision = 0 })};
    const verdict = try check(testing.allocator, &history, &.{}, .{ .final_revision = 0 });
    try testing.expectEqual(@as(?Kind, .bad_history), verdict_kind(verdict));
}

test "teeth: an event at the base revision is not part of the log" {
    const log = [_]LogEvent{put_event(5, 0, 1)};
    const none: []const Entry = &.{};
    const verdict = try check(testing.allocator, none, &log, .{
        .base_revision = 5,
        .final_revision = 5,
    });
    try testing.expectEqual(@as(?Kind, .log_disorder), verdict_kind(verdict));
    const after = [_]LogEvent{put_event(6, 0, 1)};
    const fine = try check(testing.allocator, &.{acked(
        1,
        2,
        create_one,
        .{ .succeeded = true, .revision = 6 },
    )}, &after, .{ .base_revision = 5, .final_revision = 6 });
    try testing.expectEqual(@as(?Kind, null), verdict_kind(fine));
}

test "teeth: a value token used by two calls is a bad history, not a misleading verdict" {
    const same = write(.{ .key = 1, .mod_revision = 0 }, &.{.{ .key = 1, .value = 1 }}, &.{});
    var dropped = acked(3, 4, same, .{ .succeeded = true, .revision = 0 });
    dropped.outcome = .failed;
    const history = [_]Entry{
        acked(1, 2, create_one, .{ .succeeded = true, .revision = 1 }),
        dropped,
    };
    const log = [_]LogEvent{put_event(1, 0, 1)};
    const verdict = try check(testing.allocator, &history, &log, .{ .final_revision = 1 });
    try testing.expectEqual(@as(?Kind, .bad_history), verdict_kind(verdict));
}

test "teeth: a watch must open after the log's base and report no further than its end" {
    const log = [_]LogEvent{ put_event(6, 0, 1), put_event(7, 0, 2) };
    const options: Options = .{ .base_revision = 5, .final_revision = 7 };
    const early = WatchRecord{ .from_revision = 5, .bookmark = 7, .events = &log };
    const beyond = WatchRecord{ .from_revision = 6, .bookmark = 8, .events = &log };
    const exact = WatchRecord{ .from_revision = 6, .bookmark = 7, .events = &log };
    const a = verdict_kind(check_watch(&log, early, options));
    const b = verdict_kind(check_watch(&log, beyond, options));
    try testing.expectEqual(@as(?Kind, .bad_history), a);
    try testing.expectEqual(@as(?Kind, .bad_history), b);
    try testing.expectEqual(@as(?Kind, null), verdict_kind(check_watch(&log, exact, options)));
}
