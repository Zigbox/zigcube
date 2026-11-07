//! J4 of the cluster simulation (docs/briefs/b1.md, "The checks and their teeth"): a client that
//! follows job endings through the real API and must see each one exactly once, however often it
//! is killed and however long it is away. It keeps the revision it last handled and the endings
//! it handled; it asks `GET /v1/jobs/watch?from=`, and on a 410 (`ZC-E0203`, the store compacted
//! past it) lists `state=ended`, deduplicates by `(name, epoch)` (`(name, ended_at_ms)` if
//! unplaced) and watches on from the list's revision (docs/api.md). The truth is every terminal
//! `/job-status/` put the tap saw commit.
//! Core code: it drives `Api.handle` and keeps no thread, clock or file.

const std = @import("std");
const api_mod = @import("api.zig");
const controller = @import("controller.zig");
const records = @import("records.zig");
const store = @import("store.zig");

const Context = controller.Context;

/// Endings the truth and the client's memory can hold; past it the run is counted, not judged.
pub const endings_max: u32 = 1024;

pub const Ending = struct { name_hash: u64, epoch: u64, ended_at_ms: u64 };

pub const State = struct {
    /// What the store committed: every terminal status put, once.
    truth: [endings_max]Ending = undefined,
    truth_count: u32 = 0,
    truth_full: u32 = 0,
    /// What the client handled, with the revision it resumes from (0: never started).
    handled: [endings_max]Ending = undefined,
    handled_count: u32 = 0,
    revision: store.Revision = 0,
    /// The client is away (killed) until this time.
    away_until_ms: u64 = 0,
    next_poll_ms: u64 = 0,
    restarts: u32 = 0,
    watches: u64 = 0,
    relists: u64 = 0,
    violation: ?[]const u8 = null,
};

pub fn ending_of(name: []const u8, epoch: ?u64, ended_at_ms: ?u64) Ending {
    return .{
        .name_hash = std.hash.Wyhash.hash(0, name),
        .epoch = epoch orelse 0,
        .ended_at_ms = ended_at_ms orelse 0,
    };
}

/// docs/api.md's key: `(name, epoch)` for a placed ending (epoch non-zero, a store revision),
/// `(name, ended_at_ms)` for an unplaced one.
fn same(a: Ending, b: Ending) bool {
    if (a.name_hash != b.name_hash or a.epoch != b.epoch) return false;
    return a.epoch != 0 or a.ended_at_ms == b.ended_at_ms;
}

fn exact(a: Ending, b: Ending) bool {
    return a.name_hash == b.name_hash and a.epoch == b.epoch and a.ended_at_ms == b.ended_at_ms;
}

/// Whether `list` holds this ending to the last member (the truth and coverage compare so).
fn contains(list: []const Ending, ending: Ending) bool {
    for (list) |known| {
        if (exact(known, ending)) return true;
    }
    return false;
}

/// The tap saw `request` commit: its terminal status puts are the endings.
pub fn note_commit(state: *State, request: store.TxnRequest, arena: std.mem.Allocator) void {
    for (request.on_success) |op| {
        const put = switch (op) {
            .put => |put| put,
            .delete => continue,
        };
        if (!std.mem.startsWith(u8, put.key, records.prefix_job_status)) continue;
        const parsed = std.json.parseFromSliceLeaky(
            records.JobStatus,
            arena,
            put.value,
            .{ .ignore_unknown_fields = true },
        ) catch continue;
        if (!records.job_state_terminal(parsed.state)) continue;
        const name = put.key[records.prefix_job_status.len..];
        const ending = ending_of(name, parsed.epoch, parsed.ended_at_ms);
        if (contains(state.truth[0..state.truth_count], ending)) continue;
        if (state.truth_count < endings_max) {
            state.truth[state.truth_count] = ending;
            state.truth_count += 1;
        } else {
            state.truth_full += 1;
        }
    }
}

fn handle(state: *State, ending: Ending) void {
    for (state.handled[0..state.handled_count]) |known| {
        if (!same(known, ending)) continue;
        // One placed ending under two times is one ending under two keys: the exactly-once half.
        if (known.ended_at_ms != ending.ended_at_ms and ending.epoch != 0) {
            return fail(state, "J4: one job ending was reported with two ended_at_ms values");
        }
        return;
    }
    if (state.handled_count < endings_max) {
        state.handled[state.handled_count] = ending;
        state.handled_count += 1;
    }
}

fn fail(state: *State, found: []const u8) void {
    if (state.violation == null) state.violation = found;
}

const Event = struct {
    type: []const u8,
    name: []const u8,
    revision: u64,
    status: ?records.JobStatus = null,
};
const Watched = struct { revision: u64, events: []const Event = &.{} };
const Row = struct { name: []const u8, epoch: ?u64 = null, ended_at_ms: ?u64 = null };
const Listed = struct { revision: u64, jobs: []const Row = &.{}, @"continue": ?[]const u8 = null };

const Answer = struct { status: u16, body: []const u8 };

fn get(api: *api_mod.Api, ctx: *const Context, path: []const u8, query: []const u8) Answer {
    ctx.diag.reset();
    const response = api.handle(ctx, .{
        .method = "GET",
        .path = path,
        .query = query,
        .hold = false,
    });
    return .{ .status = response.status, .body = response.body };
}

/// Lists the ended jobs, deduplicates them into `handled`, and resumes after the list's revision.
/// False if the list could not be read (try again later).
fn relist(state: *State, api: *api_mod.Api, ctx: *const Context) bool {
    state.relists += 1;
    var at: ?u64 = null;
    var after: []const u8 = "";
    for (0..1024) |_| {
        var query: [256]u8 = undefined;
        const text = if (at) |revision|
            std.fmt.bufPrint(&query, "state=ended&limit=100&at={d}&continue={s}", .{
                revision, after,
            }) catch return false
        else
            "state=ended&limit=100";
        const reply = get(api, ctx, "/v1/jobs", text);
        if (reply.status != 200) return false;
        const page = std.json.parseFromSliceLeaky(Listed, ctx.arena, reply.body, .{
            .ignore_unknown_fields = true,
        }) catch return false;
        if (at == null) at = page.revision;
        for (page.jobs) |row| handle(state, ending_of(row.name, row.epoch, row.ended_at_ms));
        after = page.@"continue" orelse {
            state.revision = at.?;
            return true;
        };
    }
    return false;
}

/// One poll of the client: a watch from the revision it holds, or the list after a 410.
pub fn poll(state: *State, api: *api_mod.Api, ctx: *const Context) void {
    if (state.violation != null) return;
    if (state.revision == 0) {
        _ = relist(state, api, ctx);
        return;
    }
    var query: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&query, "from={d}&timeout=0", .{state.revision + 1}) catch
        return;
    state.watches += 1;
    const reply = get(api, ctx, "/v1/jobs/watch", text);
    if (reply.status == 410) {
        state.revision = 0;
        _ = relist(state, api, ctx);
        return;
    }
    if (reply.status != 200) return; // A refusal under faults: ask again.
    const watched = std.json.parseFromSliceLeaky(Watched, ctx.arena, reply.body, .{
        .ignore_unknown_fields = true,
    }) catch return fail(state, "J4: the watch answered something that is not a watch");
    for (watched.events) |event| {
        if (event.revision <= state.revision) {
            return fail(state, "J4: the watch delivered an event it had already delivered");
        }
        const status = event.status orelse continue;
        if (!records.job_state_terminal(status.state)) continue;
        handle(state, ending_of(event.name, status.epoch, status.ended_at_ms));
    }
    state.revision = @max(state.revision, watched.revision);
}

/// The end of the run: the client has been up and polls until it holds the head; every ending the
/// store committed must have been handled.
pub fn finish(state: *State, api: *api_mod.Api, ctx: *const Context, head: store.Revision) void {
    if (state.violation != null) return;
    for (0..4096) |_| {
        if (state.revision >= head) break;
        const before = state.revision;
        poll(state, api, ctx);
        if (state.violation != null) return;
        if (state.revision == before) break;
    }
    if (state.truth_full > 0) return;
    for (state.truth[0..state.truth_count]) |ending| {
        if (!contains(state.handled[0..state.handled_count], ending)) {
            return fail(state, "J4: a job ending was never seen by the watching client");
        }
    }
}
