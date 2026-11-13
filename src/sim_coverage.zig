//! Coverage counters of the cluster simulation (docs/briefs/c3.md, slice 3; c3-sim-fleet.md,
//! item 5): which checks a run evaluated, which faults it injected and which code paths it
//! reached, as `name=count` pairs in the report, and, over a `--seeds` range, how many seeds of
//! each fault profile reached each name. The fleet (`sim_fleet coverage` and `bias`) adds the
//! ranges up and points new seeds at the profile that best reaches the least reached name.
//!
//! Counting only reads what the run did: it draws nothing and changes no simulated state, so a
//! seed's world (and every line of its report but the `coverage:` ones) is what it was without
//! it. Names are `<group>.<what>`: `check.` (evaluations, by the check's id, or a tally of what a
//! check judged), `fault.` (faults injected), `op.` (operations drawn) and `path.` (code paths
//! reached, `path.decision.<action>` for each decision action the controllers wrote).

const std = @import("std");
const assert = std.debug.assert;
const sim_shape = @import("sim_shape.zig");

/// Names a run can report; past it a name is dropped and counted in `Table.dropped`.
pub const names_max = 128;
/// The longest name, `path.decision.` and a decision action included.
pub const name_bytes_max = 48;
/// Distinct check ids one run tallies (`CheckIds`).
pub const check_ids_max = 16;
/// The longest check id: the text before a check message's colon (`J10`, `I1b`).
pub const check_id_bytes_max = 4;

pub const Name = struct {
    bytes: [name_bytes_max]u8 = undefined,
    len: u8 = 0,

    pub fn slice(name: *const Name) []const u8 {
        return name.bytes[0..name.len];
    }
};

/// Names and counts, at most `names_max`, kept in order of name (so a report groups by prefix
/// and reads the same on every target).
pub const Table = struct {
    names: [names_max]Name = undefined,
    counts: [names_max]u64 = undefined,
    len: u32 = 0,
    /// Names that did not fit (too long, or the table full).
    dropped: u32 = 0,

    /// Where `name` is, or where it would go.
    fn find(table: *const Table, name: []const u8) struct { index: u32, found: bool } {
        var low: u32 = 0;
        var high: u32 = table.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            switch (std.mem.order(u8, table.names[middle].slice(), name)) {
                .lt => low = middle + 1,
                .gt => high = middle,
                .eq => return .{ .index = middle, .found = true },
            }
        }
        return .{ .index = low, .found = false };
    }

    /// The slot of `name`, made with a count of 0 if it is new; null if it does not fit.
    fn slot(table: *Table, name: []const u8) ?*u64 {
        assert(name.len > 0);
        const at = table.find(name);
        if (at.found) return &table.counts[at.index];
        if (name.len > name_bytes_max or table.len == names_max) {
            table.dropped += 1;
            return null;
        }
        var index = table.len;
        while (index > at.index) : (index -= 1) {
            table.names[index] = table.names[index - 1];
            table.counts[index] = table.counts[index - 1];
        }
        table.names[at.index] = .{ .len = @intCast(name.len) };
        @memcpy(table.names[at.index].bytes[0..name.len], name);
        table.counts[at.index] = 0;
        table.len += 1;
        assert(table.len <= names_max);
        return &table.counts[at.index];
    }

    pub fn add(table: *Table, name: []const u8, count: u64) void {
        const counter = table.slot(name) orelse return;
        counter.* +|= count;
    }

    /// `name` counts at least `count`.
    pub fn at_least(table: *Table, name: []const u8, count: u64) void {
        const counter = table.slot(name) orelse return;
        counter.* = @max(counter.*, count);
    }

    /// `prefix` and `name` joined, then `add`.
    pub fn add_joined(table: *Table, prefix: []const u8, name: []const u8, count: u64) void {
        var buffer: [name_bytes_max]u8 = undefined;
        if (prefix.len + name.len > buffer.len) {
            table.dropped += 1;
            return;
        }
        @memcpy(buffer[0..prefix.len], prefix);
        @memcpy(buffer[prefix.len..][0..name.len], name);
        table.add(buffer[0 .. prefix.len + name.len], count);
    }

    pub fn get(table: *const Table, name: []const u8) u64 {
        const at = table.find(name);
        return if (at.found) table.counts[at.index] else 0;
    }

    /// One line per group of names (the text before the first dot), each `coverage: ` and then
    /// ` name=count` pairs; then `coverage: dropped=N` if any name did not fit.
    pub fn print(table: *const Table, out: *std.Io.Writer) std.Io.Writer.Error!void {
        var group: []const u8 = "";
        for (table.names[0..table.len], table.counts[0..table.len], 0..) |*name, count, index| {
            const text = name.slice();
            const this = text[0 .. std.mem.indexOfScalar(u8, text, '.') orelse text.len];
            if (index == 0 or !std.mem.eql(u8, this, group)) {
                if (index > 0) try out.writeAll("\n");
                try out.writeAll("coverage:");
                group = this;
            }
            try out.print(" {s}={d}", .{ text, count });
        }
        if (table.len > 0) try out.writeAll("\n");
        if (table.dropped > 0) try out.print("coverage: dropped={d}\n", .{table.dropped});
    }
};

/// The ids of the checks a run evaluated and how often: `check(c, ok, what)` counts under the
/// text before `what`'s colon (`J8`, `I1b`), or `c0` (sim-c0's invariants, which have none).
/// Kept apart from `Table` because it is counted on every check: a few short ids, no sorting.
pub const CheckIds = struct {
    ids: [check_ids_max][check_id_bytes_max]u8 = undefined,
    lens: [check_ids_max]u8 = undefined,
    counts: [check_ids_max]u64 = undefined,
    len: u32 = 0,
    dropped: u32 = 0,

    pub fn note(tally: *CheckIds, what: []const u8) void {
        const id = check_id(what);
        for (tally.ids[0..tally.len], tally.lens[0..tally.len], 0..) |*bytes, len, index| {
            if (std.mem.eql(u8, bytes[0..len], id)) {
                tally.counts[index] +|= 1;
                return;
            }
        }
        if (tally.len == check_ids_max) {
            tally.dropped += 1;
            return;
        }
        @memcpy(tally.ids[tally.len][0..id.len], id);
        tally.lens[tally.len] = @intCast(id.len);
        tally.counts[tally.len] = 1;
        tally.len += 1;
    }

    /// Into `table` as `check.<id>`.
    pub fn add_to(tally: *const CheckIds, table: *Table) void {
        for (tally.ids[0..tally.len], tally.lens[0..tally.len], 0..) |*bytes, len, index| {
            table.add_joined("check.", bytes[0..len], tally.counts[index]);
        }
        table.dropped += tally.dropped;
    }
};

/// The id of check message `what`: up to `check_id_bytes_max` letters and digits before a colon,
/// else `c0`.
pub fn check_id(what: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, what[0..@min(what.len, check_id_bytes_max + 1)], ':');
    const end = colon orelse return "c0";
    if (end == 0) return "c0";
    for (what[0..end]) |byte| {
        if (!std.ascii.isAlphanumeric(byte)) return "c0";
    }
    return what[0..end];
}

/// Decision actions and how many of each the store held at once (the most seen over every
/// listing of the decisions: retention deletes the old ones, so this is a floor).
pub const Actions = struct {
    table: Table = .{},

    /// One listing's counts, folded in by `at_least`.
    pub fn merge(actions: *Actions, listing: *const Table) void {
        for (listing.names[0..listing.len], listing.counts[0..listing.len]) |*name, count| {
            actions.table.at_least(name.slice(), count);
        }
    }

    pub fn add_to(actions: *const Actions, table: *Table) void {
        const t = &actions.table;
        for (t.names[0..t.len], t.counts[0..t.len]) |*name, count| {
            table.add_joined("path.decision.", name.slice(), count);
        }
        table.dropped += t.dropped;
    }
};

pub const profiles = @typeInfo(sim_shape.ClusterProfile).@"enum".field_names.len;

/// Over a `--seeds` range: per profile, the seeds run and how many of them reached each name
/// (a count above 0).
pub const Reach = struct {
    seeds: [profiles]u64 = @splat(0),
    tables: [profiles]Table = @splat(.{}),

    pub fn note(reach: *Reach, profile: sim_shape.ClusterProfile, run: *const Table) void {
        const index = @backingInt(profile);
        reach.seeds[index] += 1;
        const table = &reach.tables[index];
        for (run.names[0..run.len], run.counts[0..run.len]) |*name, count| {
            // Every name is made, reached or not, so the fleet sees what a profile never reaches.
            table.add(name.slice(), @intFromBool(count > 0));
        }
        table.dropped = @max(table.dropped, run.dropped);
    }

    /// `coverage: profile=P seeds=N name=reached ...`, one line per profile that ran.
    pub fn print(reach: *const Reach, out: *std.Io.Writer) std.Io.Writer.Error!void {
        for (reach.seeds, &reach.tables, 0..) |seeds, *table, index| {
            if (seeds == 0) continue;
            const profile: sim_shape.ClusterProfile = @fromBackingInt(@intCast(index));
            try out.print("coverage: profile={s} seeds={d}", .{ profile.name(), seeds });
            for (table.names[0..table.len], table.counts[0..table.len]) |*name, count| {
                try out.print(" {s}={d}", .{ name.slice(), count });
            }
            if (table.dropped > 0) try out.print(" dropped={d}", .{table.dropped});
            try out.writeAll("\n");
        }
    }
};

// ---- Tests --------------------------------------------------------------------------------------

const testing = std.testing;

test "a table keeps names in order, adds, keeps the most, and drops what does not fit" {
    var table: Table = .{};
    table.add("path.fence", 2);
    table.add("fault.crash", 1);
    table.add("path.fence", 3);
    table.at_least("check.J8", 4);
    table.at_least("check.J8", 1);
    try testing.expectEqual(@as(u64, 5), table.get("path.fence"));
    try testing.expectEqual(@as(u64, 4), table.get("check.J8"));
    try testing.expectEqual(@as(u64, 0), table.get("op.advance"));
    try testing.expectEqualStrings("check.J8", table.names[0].slice());
    try testing.expectEqualStrings("path.fence", table.names[2].slice());
    table.add(&(@as([name_bytes_max + 1]u8, @splat('x'))), 1);
    try testing.expectEqual(@as(u32, 1), table.dropped);
    var buffer: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try table.print(&out);
    try testing.expectEqualStrings("coverage: check.J8=4\ncoverage: fault.crash=1\n" ++
        "coverage: path.fence=5\ncoverage: dropped=1\n", out.buffered());
}

test "a full table drops new names and keeps counting old ones" {
    var table: Table = .{};
    var buffer: [16]u8 = undefined;
    for (0..names_max) |index| {
        // 16 bytes hold "n.0127": the format cannot run out of room.
        table.add(std.fmt.bufPrint(&buffer, "n.{d:0>4}", .{index}) catch unreachable, 1);
    }
    table.add("n.new", 1);
    table.add("n.0007", 1);
    try testing.expectEqual(@as(u32, 1), table.dropped);
    try testing.expectEqual(@as(u64, 2), table.get("n.0007"));
    try testing.expectEqual(@as(u64, 0), table.get("n.new"));
}

test "a check's id is the short text before its colon" {
    try testing.expectEqualStrings("J8", check_id("J8: a run kept executing"));
    try testing.expectEqualStrings("I1b", check_id("I1b: one replica executes on two nodes"));
    try testing.expectEqualStrings("J10", check_id("J10: an agent kept making reports"));
    try testing.expectEqualStrings("c0", check_id("a decision has no reason"));
    try testing.expectEqualStrings("c0", check_id("the store: cannot be read"));
    try testing.expectEqualStrings("c0", check_id(": nothing"));
    try testing.expectEqualStrings("c0", check_id(""));
    var tally: CheckIds = .{};
    tally.note("J8: x");
    tally.note("a decision has no reason");
    tally.note("J8: y");
    var table: Table = .{};
    tally.add_to(&table);
    try testing.expectEqual(@as(u64, 2), table.get("check.J8"));
    try testing.expectEqual(@as(u64, 1), table.get("check.c0"));
}

test "decision actions keep the most seen in one listing" {
    var actions: Actions = .{};
    var first: Table = .{};
    first.add("place_replica", 5);
    first.add("mark_lost", 1);
    actions.merge(&first);
    var second: Table = .{};
    second.add("place_replica", 3);
    actions.merge(&second);
    var table: Table = .{};
    actions.add_to(&table);
    try testing.expectEqual(@as(u64, 5), table.get("path.decision.place_replica"));
    try testing.expectEqual(@as(u64, 1), table.get("path.decision.mark_lost"));
}

test "reach counts the seeds of a profile that reached each name" {
    var reach: Reach = .{};
    var hit: Table = .{};
    hit.add("fault.crash", 3);
    hit.add("path.fence", 0);
    var miss: Table = .{};
    miss.add("fault.crash", 0);
    reach.note(.crash_heavy, &hit);
    reach.note(.crash_heavy, &miss);
    reach.note(.skew, &miss);
    var buffer: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try reach.print(&out);
    try testing.expectEqualStrings(
        "coverage: profile=skew seeds=1 fault.crash=0\n" ++
            "coverage: profile=crash_heavy seeds=2 fault.crash=1 path.fence=0\n",
        out.buffered(),
    );
}
