//! C3's witness (`c3-smoke`, and the KVM `demo-c3` to come): it follows the store's watch
//! (`GET /v1/watch`) from before step 1 and judges C3's rollout rules at **every revision** of
//! the demo's service, not by sampling (the brief's "How demo-c3 runs"). It keeps a mirror of
//! the keys it watches, so each revision is judged on the state before it and the state after
//! it:
//!
//!   R1  a revision that retires a ready replica of an older spec while a rollout is active
//!       leaves at least `replicas - max_unavailable` ready (before it, the ready count less the
//!       ready replicas it retired);
//!   R2  replicas live (a record not reported stopped, and a report of a removed replica that has
//!       not stopped yet) never exceed `replicas + max_surge` while the service has a rollout;
//!   R3  a replica created runs its service's image at its generation, or the image `/history`
//!       holds for that generation;
//!   R4  a revision under a paused rollout starts and retires nothing (a dead replica may be
//!       replaced: it never is in this demo);
//!   R5  when a rollback's rollout completes, every replica runs its generation and the image of
//!       the generation it restored.
//!
//! "Ready" is what the rollout controller counts: the replica's report says running and, since
//! every replica of the demo has a health check, healthy. Step 2 also turns on the floor of
//! "never fewer than 3 ready" at every revision of its rollout.
//!
//! The witness reads the API with `timeout=0` and is drained from every poll of every wait of the
//! demo, so it stays far ahead of compaction (60 s, 1000 revisions kept). It also plays the part
//! of the `v3` image: every replica created with `fault_image` gets `unhealthy` in each node's
//! fault directory (FakeRuntime's scripted health), and a `v3` replica reported healthy fails the
//! run, since the step would then prove nothing.

const std = @import("std");
const assert = std.debug.assert;
const demo_host = @import("demo_host.zig");
const diag_mod = @import("diag.zig");
const records = @import("records.zig");
const store = @import("store.zig");

const Host = demo_host.Host;
const Json = demo_host.Json;

pub const service = "app";
pub const replicas: u32 = 3;
pub const max_surge: u32 = 1;
pub const max_unavailable: u32 = 0;

const prefix_replicas = "/replicas/" ++ service ++ "/";
const prefix_observed = "/observed/";
const key_service = "/services/" ++ service;
const key_rollout = "/rollouts/" ++ service;
const prefix_history = "/history/" ++ service ++ "/";

/// The most watch replies one drain reads before it lets the demo go on.
const replies_max: u32 = 256;

pub const Witness = struct {
    host: *Host,
    /// The mirror: key to value (the record's JSON text), as of revision `from - 1`.
    kvs: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    /// The image of every replica ever created, by id: a report outlives its record.
    images: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    /// The next revision to ask for.
    from: u64 = 0,
    /// Each node's FakeRuntime fault directory, `<state-dir>/faults`.
    fault_dirs: []const []const u8 = &.{},
    /// Replicas created with this image get `unhealthy` scripted on every node.
    fault_image: ?[]const u8 = null,
    /// Step 2: the floor of `replicas - max_unavailable` ready at every revision.
    floor: bool = false,
    tally: Tally = .{},

    pub const Tally = struct {
        revisions: u64 = 0,
        retirements: u64 = 0,
        created: u64 = 0,
        paused: u64 = 0,
        rollbacks_completed: u64 = 0,
        live_max: u32 = 0,
        floor_revisions: u64 = 0,
        floor_low: u32 = std.math.maxInt(u32),
        faults_written: u32 = 0,
    };

    /// Starts at the store's head: the demo's service does not exist yet.
    pub fn start(witness: *Witness) !void {
        const host = witness.host;
        const listed = try host.json("/v1/list?prefix=" ++ key_service);
        const revision = demo_host_number(listed, "revision") orelse
            return host.fail("GET /v1/list has no revision", .{});
        witness.from = @intCast(revision + 1);
        host.say("  the witness follows the store's watch from revision {d}", .{witness.from});
    }

    /// Reads and judges every revision the server has, up to its head. A server that does not
    /// answer (it is being restarted) is read next time.
    pub fn drain(witness: *Witness) !void {
        const host = witness.host;
        for (0..replies_max) |_| {
            const path = try std.fmt.allocPrint(host.arena(), "/v1/watch?prefix=" ++ key_service ++
                "&prefix=" ++ prefix_replicas ++ "&prefix=" ++ prefix_observed ++
                "&prefix=" ++ key_rollout ++ "&prefix=" ++ prefix_history ++
                "&from={d}&timeout=0", .{witness.from});
            const reply = host.call("GET", path, "") catch return;
            if (reply.status == 410) {
                return host.fail("the witness fell behind compaction at revision {d}", .{
                    witness.from,
                });
            }
            if (reply.status != 200) return;
            const parsed = try std.json.parseFromSliceLeaky(Json, host.arena(), reply.body, .{});
            const bookmark = demo_host_number(parsed, "revision") orelse
                return host.fail("a watch reply has no revision", .{});
            const events = events_of(parsed) orelse
                return host.fail("a watch reply has no events", .{});
            try witness.judge_events(events);
            const next: u64 = @intCast(bookmark + 1);
            const done = events.len == 0 and next <= witness.from;
            witness.from = @max(witness.from, next);
            if (done) return;
        }
    }

    /// Lets time pass while the witness keeps reading.
    pub fn watch_for(witness: *Witness, comptime why: []const u8, duration_ms: u32) !void {
        const host = witness.host;
        host.say("  (watching for {d} ms: " ++ why ++ ")", .{duration_ms});
        const started = host.now_ms();
        while (host.now_ms() - started < duration_ms) {
            try witness.drain();
            try host.io.sleep(.fromMilliseconds(demo_host.poll_ms), .awake);
        }
        try witness.drain();
    }

    /// Splits the events into revisions and judges each.
    fn judge_events(witness: *Witness, events: []const Json) !void {
        var first: usize = 0;
        while (first < events.len) {
            const revision = event_revision(events[first]) orelse
                return witness.host.fail("a watch event has no mod_revision", .{});
            var end = first + 1;
            while (end < events.len and event_revision(events[end]) == revision) end += 1;
            try witness.judge(revision, events[first..end]);
            first = end;
        }
    }

    fn judge(witness: *Witness, revision: i64, events: []const Json) !void {
        const host = witness.host;
        witness.tally.revisions += 1;
        const before = try witness.view();
        var changes: std.ArrayList(Change) = .empty;
        for (events) |event| try changes.append(host.arena(), try change_of(host, event));
        if (try witness.before_problem(&before, changes.items)) |problem| {
            return host.fail("witness, revision {d}: {s}", .{ revision, problem });
        }
        for (changes.items) |change| {
            if (change.value) |value| {
                try witness.kvs.put(host.arena(), change.key, value);
            } else {
                _ = witness.kvs.orderedRemove(change.key);
            }
        }
        const after = try witness.view();
        try witness.created(&before, &after, changes.items);
        if (try witness.after_problem(&before, &after)) |problem| {
            return host.fail("witness, revision {d}: {s}", .{ revision, problem });
        }
    }

    // ---- The mirror, decoded ----

    fn view(witness: *Witness) !View {
        const host = witness.host;
        var result: View = .{};
        var replica_list: std.ArrayList(records.Replica) = .empty;
        var observed_list: std.ArrayList(records.Observed) = .empty;
        var history_list: std.ArrayList(records.History) = .empty;
        var iterator = witness.kvs.iterator();
        while (iterator.next()) |entry| {
            const key = entry.key_ptr.*;
            const value = entry.value_ptr.*;
            if (std.mem.eql(u8, key, key_service)) {
                result.service = try decode(records.Service, host, key, value);
            } else if (std.mem.eql(u8, key, key_rollout)) {
                result.rollout = try decode(records.Rollout, host, key, value);
            } else if (std.mem.startsWith(u8, key, prefix_replicas)) {
                const replica = try decode(records.Replica, host, key, value);
                try replica_list.append(host.arena(), replica);
            } else if (std.mem.startsWith(u8, key, prefix_history)) {
                const stored = try decode(records.History, host, key, value);
                try history_list.append(host.arena(), stored);
            } else if (std.mem.startsWith(u8, key, prefix_observed)) {
                const observed = try decode(records.Observed, host, key, value);
                if (records.replica_number(service, observed.replica) == null) continue;
                try observed_list.append(host.arena(), observed);
            }
        }
        result.replicas = replica_list.items;
        result.observed = observed_list.items;
        result.history = history_list.items;
        return result;
    }

    // ---- The rules ----

    /// R1 and R4: what the revision removes, judged on the state before it.
    fn before_problem(
        witness: *Witness,
        before: *const View,
        changes: []const Change,
    ) !?[]const u8 {
        const current = before.service orelse return null;
        const rollout = before.rollout orelse return null;
        var retired: u32 = 0;
        var retired_ready: u32 = 0;
        var started: u32 = 0;
        for (changes) |change| {
            if (!std.mem.startsWith(u8, change.key, prefix_replicas)) continue;
            const id = change.key[prefix_replicas.len..];
            const old = before.replica(id) orelse {
                if (change.value != null) started += 1;
                continue;
            };
            if (change.value != null) continue;
            if (!before.live(old)) continue; // A dead replica removed: not a retirement.
            if (old.generation >= current.generation and
                records.replica_runs_service(old, &current)) continue;
            retired += 1;
            if (before.ready(old)) retired_ready += 1;
        }
        if (rollout.phase == .paused) {
            if (retired + started > 0) witness.tally.paused += 1;
            if (retired > 0) return "R4: a paused rollout retired a replica";
            if (started > 0) return "R4: a paused rollout started a replica";
            return null;
        }
        if (rollout.phase != .progressing and rollout.phase != .rolling_back) return null;
        if (retired_ready == 0) return null;
        witness.tally.retirements += retired_ready;
        if (before.ready_count() - retired_ready < replicas - max_unavailable) {
            return "R1: a retirement left fewer ready replicas than replicas - max_unavailable";
        }
        return null;
    }

    /// R2, R3, R5, the floor and the `v3` premise, judged on the state after the revision.
    fn after_problem(witness: *Witness, before: *const View, after: *const View) !?[]const u8 {
        const current = after.service orelse return null;
        const tally = &witness.tally;
        if (after.rollout != null) {
            const live = after.live_count();
            tally.live_max = @max(tally.live_max, live);
            if (live > replicas + max_surge) return "R2: more replicas live than replicas + surge";
        }
        for (after.replicas) |*replica| {
            if (before.replica(replica.id) != null) continue;
            if (replica.generation == current.generation) {
                if (!std.mem.eql(u8, replica.image, current.image)) {
                    return "R3: a replica runs another image than its generation's";
                }
            } else {
                const stored = after.history_of(replica.generation) orelse
                    return "R3: a replica runs a generation its service never had";
                if (!std.mem.eql(u8, replica.image, stored.image)) {
                    return "R3: a replica runs another image than its generation's";
                }
            }
        }
        if (try witness.rollback_completed(before, after)) |problem| return problem;
        if (witness.floor) {
            tally.floor_revisions += 1;
            tally.floor_low = @min(tally.floor_low, after.ready_count());
            if (after.ready_count() < replicas - max_unavailable) {
                return "step 2: fewer than 3 replicas ready during the rollout";
            }
        }
        const image = witness.fault_image orelse return null;
        for (after.observed) |*observed| {
            const replica_image = witness.images.get(observed.replica) orelse continue;
            if (!std.mem.eql(u8, replica_image, image)) continue;
            if (observed.health == .healthy) return "a v3 replica was reported healthy";
        }
        return null;
    }

    /// R5: the revision that marks a rollback's rollout complete leaves every replica at the
    /// rollback's generation, with the image of the generation it restored.
    fn rollback_completed(witness: *Witness, before: *const View, after: *const View) !?[]const u8 {
        const rollout = after.rollout orelse return null;
        if (rollout.phase != .complete) return null;
        if (before.rollout) |previous| {
            if (previous.phase == .complete and previous.to == rollout.to) return null;
        }
        const landed = after.history_of(rollout.to) orelse return null;
        if (landed.reason == .apply) return null;
        const restored = after.history_of(landed.restores orelse 0) orelse
            return "R5: a rollback restored a generation the history does not hold";
        witness.tally.rollbacks_completed += 1;
        for (after.replicas) |*replica| {
            if (replica.generation != rollout.to) {
                return "R5: a completed rollback left a replica of another generation";
            }
            if (!std.mem.eql(u8, replica.image, restored.image)) {
                return "R5: a completed rollback left a replica of another image";
            }
        }
        return null;
    }

    /// Remembers each new replica's image and scripts `unhealthy` for one of `fault_image`.
    fn created(
        witness: *Witness,
        before: *const View,
        after: *const View,
        changes: []const Change,
    ) !void {
        _ = changes;
        const host = witness.host;
        for (after.replicas) |*replica| {
            if (before.replica(replica.id) != null) continue;
            if (witness.images.get(replica.id) != null) continue;
            witness.tally.created += 1;
            try witness.images.put(host.arena(), replica.id, replica.image);
            const image = witness.fault_image orelse continue;
            if (!std.mem.eql(u8, replica.image, image)) continue;
            try witness.script_unhealthy(replica.id);
        }
    }

    /// Writes `unhealthy` into `<state-dir>/faults/<id>` of every node: FakeRuntime's health check
    /// of that container fails from its first run until the container ends.
    pub fn script_unhealthy(witness: *Witness, id: []const u8) !void {
        const host = witness.host;
        for (witness.fault_dirs) |dir| {
            try std.Io.Dir.cwd().createDirPath(host.io, dir);
            const path = try std.fmt.allocPrint(host.arena(), "{s}/{s}", .{ dir, id });
            try std.Io.Dir.cwd().writeFile(host.io, .{ .sub_path = path, .data = "unhealthy\n" });
        }
        witness.tally.faults_written += 1;
    }

    // ---- Reads for the steps ----

    pub fn now(witness: *Witness) !View {
        try witness.drain();
        return witness.view();
    }
};

/// The mirror decoded, at one revision.
pub const View = struct {
    service: ?records.Service = null,
    rollout: ?records.Rollout = null,
    replicas: []const records.Replica = &.{},
    observed: []const records.Observed = &.{},
    history: []const records.History = &.{},

    pub fn replica(view: *const View, id: []const u8) ?*const records.Replica {
        for (view.replicas) |*found| {
            if (std.mem.eql(u8, found.id, id)) return found;
        }
        return null;
    }

    pub fn observed_of(view: *const View, id: []const u8) ?*const records.Observed {
        for (view.observed) |*found| {
            if (std.mem.eql(u8, found.replica, id)) return found;
        }
        return null;
    }

    pub fn history_of(view: *const View, generation: u64) ?*const records.History {
        for (view.history) |*found| {
            if (found.generation == generation) return found;
        }
        return null;
    }

    /// Not reported stopped (a replica not reported yet counts: it is starting).
    pub fn live(view: *const View, replica_record: *const records.Replica) bool {
        const observed = view.observed_of(replica_record.id) orelse return true;
        return observed.status != .stopped;
    }

    /// Reported running and, with a health check, healthy.
    pub fn ready(view: *const View, replica_record: *const records.Replica) bool {
        const observed = view.observed_of(replica_record.id) orelse return false;
        if (observed.status != .running) return false;
        if (replica_record.health == null) return true;
        return observed.health == .healthy;
    }

    pub fn ready_count(view: *const View) u32 {
        var count: u32 = 0;
        for (view.replicas) |*found| count += @intFromBool(view.ready(found));
        return count;
    }

    /// Records not reported stopped, and reports of removed replicas that have not stopped.
    pub fn live_count(view: *const View) u32 {
        var count: u32 = 0;
        for (view.replicas) |*found| count += @intFromBool(view.live(found));
        for (view.observed) |*observed| {
            if (observed.status == .stopped) continue;
            if (view.replica(observed.replica) == null) count += 1;
        }
        return count;
    }

    /// True when every one of `replicas` records is ready at `generation` with `image`, and
    /// nothing else of the service still runs.
    pub fn settled_at(view: *const View, generation: u64, image: []const u8) bool {
        if (view.replicas.len != replicas) return false;
        for (view.replicas) |*found| {
            if (found.generation != generation) return false;
            if (!std.mem.eql(u8, found.image, image)) return false;
            if (!view.ready(found)) return false;
        }
        return view.live_count() == replicas;
    }

    /// How many replica records run `generation`.
    pub fn at_generation(view: *const View, generation: u64) u32 {
        var count: u32 = 0;
        for (view.replicas) |*found| count += @intFromBool(found.generation == generation);
        return count;
    }
};

const Change = struct { key: []const u8, value: ?[]const u8 };

fn change_of(host: *Host, event: Json) !Change {
    const bad = "a watch event is not shaped as docs/api.md says";
    if (event != .object) return host.fail(bad, .{});
    const kind = event.object.get("type") orelse return host.fail(bad, .{});
    const kv = event.object.get("kv") orelse return host.fail(bad, .{});
    if (kind != .string or kv != .object) return host.fail(bad, .{});
    const key = kv.object.get("key") orelse return host.fail(bad, .{});
    if (key != .string) return host.fail(bad, .{});
    if (std.mem.eql(u8, kind.string, "delete")) return .{ .key = key.string, .value = null };
    const value = kv.object.get("value") orelse return host.fail(bad, .{});
    const text = try std.json.Stringify.valueAlloc(host.arena(), value, .{});
    return .{ .key = key.string, .value = text };
}

fn decode(comptime T: type, host: *Host, key: []const u8, value: []const u8) !T {
    var diag: diag_mod.Diag = undefined;
    diag.reset();
    const kv: store.KeyValue = .{
        .key = key,
        .value = value,
        .create_revision = 1,
        .mod_revision = 1,
    };
    return records.read(T, host.arena(), kv, &diag) catch
        host.fail("the witness cannot read {s}: {s}", .{ key, value });
}

fn events_of(parsed: Json) ?[]const Json {
    if (parsed != .object) return null;
    const found = parsed.object.get("events") orelse return null;
    if (found != .array) return null;
    return found.array.items;
}

fn event_revision(event: Json) ?i64 {
    if (event != .object) return null;
    const kv = event.object.get("kv") orelse return null;
    return demo_host_number(kv, "mod_revision");
}

fn demo_host_number(value: Json, name: []const u8) ?i64 {
    if (value != .object) return null;
    const found = value.object.get(name) orelse return null;
    return switch (found) {
        .integer => |integer| integer,
        else => null,
    };
}
