//! Signed jobs in the cluster simulation, and J12 (docs/briefs/b5.md, slice 3). With
//! `Options.signed`, every job carries 0 to 3 lines drawn from envelopes signed by a seeded set of
//! keys, and each node runs under a trust policy of its own: none, one that asks for nothing, or
//! one that requires a signature by a seeded subset of the keys. The server has no policy, so
//! every run reaches its node, and the node's check (`job_trust.judge_run`) decides.
//!
//! J12: no run of a job that its node's policy refuses ever starts, and every refused run ends
//! `refused` exactly once. The oracle here decides admission from what the world drew, not from
//! the verdict: a line counts when it is a tree-only statement about the job's tree signed by a
//! key the node's policy lists. The other envelopes are a statement about another tree and one
//! bound to a manifest (sim jobs have no `source`, so it binds to nothing they run).
//!
//! Core code: the keys, envelopes and policies are made once, at the cluster's creation, from the
//! seed through generators of their own, so a world without `signed` draws as before.

const std = @import("std");
const assert = std.debug.assert;
const job_trust = @import("job_trust.zig");
const fixture_mod = @import("job_trust_fixture.zig");
const records = @import("records.zig");
const store = @import("store.zig");
const zigbox = @import("zigbox");

const Allocator = std.mem.Allocator;
const Policy = zigbox.trust.policy.Policy;

/// Keys that sign: the first `trusted_keys` may be in a node's policy, the last never is.
pub const keys_count: u32 = 5;
const trusted_keys: u32 = 4;
/// What each key signs: the job's tree alone, another tree, and the job's tree bound to a
/// manifest.
const Kind = enum(u8) { tree, other_tree, manifest };
const kinds_count: u32 = std.enums.values(Kind).len;
const envelopes_count: u32 = keys_count * kinds_count;
pub const lines_max: u32 = 3;

const tree_byte: u8 = 0x5a;
const other_tree_byte: u8 = 0x6b;
const manifest_byte: u8 = 0x7c;
/// The image of every job in the signed world: a tree, which the node's check needs.
pub const image = "b3:5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a";

comptime {
    assert(image.len == 3 + 64);
}

/// The policy path the node record names.
const policy_path = "/etc/zbx/policy.zon";

pub const Mode = enum { none, open, require };

pub const NodeTrust = struct {
    mode: Mode,
    /// The keys (bit i: key i) the policy lists; empty unless `require`.
    mask: u8,
    policy: *Policy,
    config: job_trust.Trust,
};

/// Terminal statuses that ended `refused`, as J12 remembers them.
pub const endings_max: u32 = 1024;
const Ending = struct { name_hash: u64, epoch: u64, ended_at_ms: u64 };
const Lines = struct { index: [lines_max]u32 = undefined, count: u32 = 0 };

pub const World = struct {
    seed: u64,
    key_seeds: [keys_count]u8,
    envelopes: [envelopes_count][]const u8,
    fixture: fixture_mod.Fixture,
    nodes: []NodeTrust,
    /// J12's first half: a run started on a node whose policy refuses it (sticky).
    started_refused: bool = false,
    /// J12's second half, judged at each commit.
    violation: ?[]const u8 = null,
    refused: [endings_max]Ending = undefined,
    refused_count: u32 = 0,
    refused_full: u32 = 0,
    /// For the report: starts judged by the oracle, and of those the ones a policy checked.
    starts: u64 = 0,
    starts_checked: u64 = 0,
    /// Terminal refused endings judged at rest.
    judged_at_rest: u64 = 0,

    pub fn init(world: *World, gpa: Allocator, seed: u64, nodes: u32) Allocator.Error!void {
        world.make(gpa, seed, nodes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // The keys, statements and policy text are this file's own, and fit their buffers.
            else => unreachable,
        };
    }

    fn make(world: *World, gpa: Allocator, seed: u64, nodes: u32) !void {
        world.* = .{
            .seed = seed,
            .key_seeds = undefined,
            .envelopes = undefined,
            .fixture = try fixture_mod.Fixture.init(gpa),
            .nodes = &.{},
        };
        errdefer world.fixture.deinit(gpa);
        draw_keys(world);
        var signed: usize = 0;
        errdefer for (world.envelopes[0..signed]) |line| gpa.free(line);
        for (&world.envelopes, 0..) |*slot, index| {
            const key = world.key_seeds[index / kinds_count];
            const kind: Kind = @fromBackingInt(@intCast(index % kinds_count));
            slot.* = try switch (kind) {
                .tree => world.fixture.sign_tree(gpa, key, tree_byte),
                .other_tree => world.fixture.sign_tree(gpa, key, other_tree_byte),
                .manifest => world.fixture.sign_manifest(gpa, key, tree_byte, manifest_byte),
            };
            signed += 1;
        }
        world.nodes = try gpa.alloc(NodeTrust, nodes);
        errdefer gpa.free(world.nodes);
        var made: usize = 0;
        errdefer for (world.nodes[0..made]) |node| gpa.destroy(node.policy);
        for (world.nodes, 0..) |*node, index| {
            node.policy = try gpa.create(Policy);
            made += 1;
            try draw_policy(world, node, @intCast(index));
        }
    }

    pub fn deinit(world: *World, gpa: Allocator) void {
        for (world.nodes) |node| gpa.destroy(node.policy);
        gpa.free(world.nodes);
        for (world.envelopes) |line| gpa.free(line);
        world.fixture.deinit(gpa);
        world.* = undefined;
    }

    /// Distinct key seeds from the world's own generator.
    fn draw_keys(world: *World) void {
        var prng = std.Random.DefaultPrng.init(stream(world.seed, "keys", 0));
        var count: u32 = 0;
        while (count < keys_count) {
            const byte = prng.random().intRangeAtMost(u8, 1, 255);
            if (std.mem.indexOfScalar(u8, world.key_seeds[0..count], byte) != null) continue;
            world.key_seeds[count] = byte;
            count += 1;
        }
    }

    /// One node in eight runs without a policy, one in eight under a policy that asks for
    /// nothing, and the rest require a signature by one of a subset of the trusted keys. The
    /// draws are the same for every mode, so a node's mode does not move the next one's.
    fn draw_policy(world: *World, node: *NodeTrust, index: u32) !void {
        var prng = std.Random.DefaultPrng.init(stream(world.seed, "policy", index));
        const random = prng.random();
        node.mode = switch (random.uintLessThan(u8, 8)) {
            0 => .none,
            1 => .open,
            else => .require,
        };
        // Seven requiring policies in eight list the first key; each lists one key at least.
        var mask: u8 = random.uintLessThan(u8, 1 << trusted_keys) & 0b1110;
        if (random.uintLessThan(u8, 8) != 0) mask |= 1;
        if (mask == 0) mask = 0b0010;
        node.mask = if (node.mode == .require) mask else 0;
        var buffer: [1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try writer.writeAll(".{ .version = 1, .keys = .{ ");
        for (0..trusted_keys) |key| {
            if (node.mask & (@as(u8, 1) << @intCast(key)) == 0) continue;
            const text = fixture_mod.public_text(world.key_seeds[key]);
            try writer.print(".{{ .name = \"key-{d}\", .public = \"{s}\" }}, ", .{ key, &text });
        }
        try writer.print("}}, .require_signature = {} }}", .{node.mode == .require});
        if (zigbox.trust.policy.parse(writer.buffered(), node.policy)) |_| {
            return error.BadPolicy;
        }
        assert(node.policy.checks() == (node.mode == .require));
        node.config = .{
            .policy = node.policy,
            .path = policy_path,
            .scratch = world.fixture.scratch,
        };
    }

    /// The node's configuration for its agent; null for a node without a policy.
    pub fn config_of(world: *const World, node: u32) ?*const job_trust.Trust {
        const trust = &world.nodes[node];
        return if (trust.mode == .none) null else &trust.config;
    }

    /// The envelopes job `number` carries: a function of the seed and the number, so a job made
    /// again under its name carries the same lines. Three jobs in four lead with the first key's
    /// signature of their tree, the key most policies list; the rest of the lines are any.
    fn draw_lines(world: *const World, number: u32) Lines {
        var prng = std.Random.DefaultPrng.init(stream(world.seed, "lines", number));
        const random = prng.random();
        var lines: Lines = .{};
        if (random.uintLessThan(u8, 4) != 0) {
            lines.index[0] = 0; // Key 0, `Kind.tree`.
            lines.count = 1;
        }
        const more = random.uintAtMost(u32, lines_max - lines.count);
        for (0..more) |_| {
            lines.index[lines.count] = random.uintLessThan(u32, envelopes_count);
            lines.count += 1;
        }
        assert(lines.count <= lines_max);
        return lines;
    }

    pub fn lines_of(world: *const World, number: u32, out: *[lines_max][]const u8) [][]const u8 {
        const lines = world.draw_lines(number);
        for (out[0..lines.count], lines.index[0..lines.count]) |*line, index| {
            line.* = world.envelopes[index];
        }
        return out[0..lines.count];
    }

    /// The oracle: whether node `node`'s policy admits job `number`.
    pub fn admits(world: *const World, node: u32, number: u32) bool {
        const trust = world.nodes[node];
        if (trust.mode != .require) return true;
        const lines = world.draw_lines(number);
        for (lines.index[0..lines.count]) |index| {
            const key = index / kinds_count;
            const kind: Kind = @fromBackingInt(@intCast(index % kinds_count));
            if (kind != .tree or key >= trusted_keys) continue;
            if (trust.mask & (@as(u8, 1) << @intCast(key)) != 0) return true;
        }
        return false;
    }

    /// A node's runtime is about to start a container of job `number`: J12's first half.
    pub fn note_start(world: *World, node: u32, number: u32) void {
        world.starts += 1;
        if (world.nodes[node].mode == .require) world.starts_checked += 1;
        if (!world.admits(node, number)) world.started_refused = true;
    }

    /// The tap saw `request` commit: each terminal status that ended `refused` must be of a run
    /// its node's policy refuses, and a run ends refused once.
    pub fn note_commit(world: *World, request: store.TxnRequest, arena: Allocator) void {
        for (request.on_success) |op| {
            const put = switch (op) {
                .put => |put| put,
                .delete => continue,
            };
            if (!std.mem.startsWith(u8, put.key, records.prefix_job_status)) continue;
            const status = std.json.parseFromSliceLeaky(
                records.JobStatus,
                arena,
                put.value,
                .{ .ignore_unknown_fields = true },
            ) catch continue;
            if (!records.job_state_terminal(status.state)) continue;
            const name = put.key[records.prefix_job_status.len..];
            world.note_ending(name, status);
        }
    }

    fn note_ending(world: *World, name: []const u8, status: records.JobStatus) void {
        const ending: Ending = .{
            .name_hash = std.hash.Wyhash.hash(0, name),
            .epoch = status.epoch orelse 0,
            .ended_at_ms = status.ended_at_ms orelse 0,
        };
        const was_refused = refused_before(world, ending);
        if (!ended_refused(status)) {
            if (was_refused) fail(world, "J12: a run that ended refused ended again otherwise");
            return;
        }
        if (was_refused) {
            if (!known_exactly(world, ending)) fail(world, "J12: a run ended refused twice");
            return;
        }
        const node = node_index(status.node orelse "") orelse
            return fail(world, "J12: a run ended refused on no node");
        const number = job_number(name) orelse return;
        if (node >= world.nodes.len) return fail(world, "J12: a run ended refused on no node");
        if (world.admits(node, number)) {
            return fail(world, "J12: a run ended refused on a node whose policy admits it");
        }
        if (world.refused_count < endings_max) {
            world.refused[world.refused_count] = ending;
            world.refused_count += 1;
        } else {
            world.refused_full += 1;
        }
    }

    /// At rest: a run of job `number` that ended on `node` without a stop cause, where the policy
    /// refuses it, ended `refused` (a stop cause, such as a cancel or the deadline, can end a run
    /// before its node judged it).
    pub fn judge_at_rest(
        world: *World,
        number: u32,
        status: records.JobStatus,
    ) ?[]const u8 {
        if (!records.job_state_terminal(status.state)) return null;
        if (status.stop_cause != null) return null;
        const node = node_index(status.node orelse return null) orelse return null;
        if (node >= world.nodes.len) return null;
        if (world.admits(node, number)) return null;
        world.judged_at_rest += 1;
        if (!ended_refused(status)) return "J12: a run its node's policy refuses ended otherwise";
        return null;
    }

    pub fn problem(world: *const World) ?[]const u8 {
        if (world.started_refused) return "J12: a run started on a node whose policy refuses it";
        return world.violation;
    }

    pub fn print(world: *const World, writer: anytype) void {
        var modes: [3]u32 = .{ 0, 0, 0 };
        for (world.nodes) |node| modes[@backingInt(node.mode)] += 1;
        writer.print("jobs: trust nodes none={d} open={d} require={d} starts={d} checked={d} " ++
            "refused endings={d} judged at rest={d}\n", .{
            modes[0],             modes[1],             modes[2],
            world.starts,         world.starts_checked, world.refused_count,
            world.judged_at_rest,
        });
    }
};

/// The seed of one stream of draws: the world's seed, a label and an index hashed together, since
/// seeds that differ in a few low bits give the generator's first draws a visible bias.
fn stream(seed: u64, label: []const u8, index: u64) u64 {
    var hasher = std.hash.Wyhash.init(seed);
    hasher.update(label);
    hasher.update(std.mem.asBytes(&index));
    return hasher.final();
}

fn ended_refused(status: records.JobStatus) bool {
    const end = status.end orelse return false;
    return end.kind == .failed and end.cause == .refused;
}

/// Whether a placed run (name, epoch) already ended refused.
fn refused_before(world: *const World, ending: Ending) bool {
    if (ending.epoch == 0) return false;
    for (world.refused[0..world.refused_count]) |known| {
        if (known.name_hash == ending.name_hash and known.epoch == ending.epoch) return true;
    }
    return false;
}

fn known_exactly(world: *const World, ending: Ending) bool {
    for (world.refused[0..world.refused_count]) |known| {
        if (std.meta.eql(known, ending)) return true;
    }
    return false;
}

fn fail(world: *World, found: []const u8) void {
    if (world.violation == null) world.violation = found;
}

/// "nodeN" (from 1) to its index.
fn node_index(name: []const u8) ?u32 {
    if (!std.mem.startsWith(u8, name, "node")) return null;
    const number = std.fmt.parseInt(u32, name["node".len..], 10) catch return null;
    if (number == 0) return null;
    return number - 1;
}

/// The job number of a name the simulation made ("jb-N").
pub fn job_number(name: []const u8) ?u32 {
    if (!std.mem.startsWith(u8, name, "jb-")) return null;
    return std.fmt.parseInt(u32, name["jb-".len..], 10) catch null;
}

test "the oracle agrees with the node's verdict" {
    const gpa = std.testing.allocator;
    var world: World = undefined;
    try world.init(gpa, 42, 8);
    defer world.deinit(gpa);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var admitted: u32 = 0;
    var refused: u32 = 0;
    for (0..8) |node| {
        const config = world.config_of(@intCast(node)) orelse continue;
        for (1..40) |number| {
            var buffer: [lines_max][]const u8 = undefined;
            const lines = world.lines_of(@intCast(number), &buffer);
            const verdict = try job_trust.judge_run(config, arena_state.allocator(), .{
                .image = image,
                .source = "",
                .signatures = lines,
            });
            const admits = world.admits(@intCast(node), @intCast(number));
            try std.testing.expectEqual(admits, verdict == null);
            if (admits) admitted += 1 else refused += 1;
        }
    }
    try std.testing.expect(admitted > 0);
    try std.testing.expect(refused > 0);
}

test "a world that runs out of memory frees what it made" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, make_and_free, .{});
}

fn make_and_free(gpa: Allocator) Allocator.Error!void {
    var world: World = undefined;
    try world.init(gpa, 7, 3);
    world.deinit(gpa);
}
