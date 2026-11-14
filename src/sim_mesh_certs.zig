//! C4 slice 3: service certificates in the cluster simulation (docs/briefs/c4.md, "Identity" and
//! "Simulation"). A service replica's supervisor makes a key, asks the server for the replica's
//! certificate, renews it at half-life with a new key, and takes the replica off the mesh
//! (ZC-W0703) when it expires unrenewed; the replica keeps running. The server's side is `issue`:
//! `service_cert.look_up` and `service_cert.decide` over the store as committed, the two calls
//! `agent_api.replica_subject` makes. Until B7 the request is not authenticated
//! (O4), so anyone may ask for any replica: `forge_one` asks as a stale epoch, another node and
//! another image.
//!
//! Three checks with teeth (`c1_teeth.zig`), in strong worlds:
//! - M3, at each issue: every issued certificate names the service, digest and epoch of a replica
//!   that was current and assigned to the asking node at the issue revision; no forged ask gets
//!   one (`mesh_issue_stale` breaks its epoch clause, `mesh_issue_any_node` its node clause).
//! - M6, at each issue: a certificate's digest equals its replica's digest, and a key is certified
//!   for one replica and one digest only, so a digest change gives a new key (`mesh_reuse_key`
//!   breaks it).
//! - M3r, at each tick after the heal: a running replica whose node is up and connected, and which
//!   the issuer would certify, holds a certificate before half-life again within
//!   `ask_interval_ms + renew_cut_ms` of needing one (`mesh_renew_late`, a supervisor that renews
//!   only at expiry, breaks it). Like J10 it is judged only once the faults have ended.
//!
//! These checks judge the simulator's model of the supervisor (key, ask, renewal, ZC-W0703): the
//! agent and the real supervisor do none of it yet (docs/demos/c4.md, "Cuts"), and the slice that
//! brings them must put them under this simulation.
//!
//! The supervisor learns its replica's epoch by reading the node's `/assigned/<node>/<id>` from
//! the store as committed, which stands for the agent's watch; a stale epoch comes only from a
//! forgery. The checker reads the records itself and does not call `service_cert`: it would
//! otherwise judge the rule by the rule. The model draws from its own generator, so a world's
//! other draws are the ones they were before C4.

const std = @import("std");
const assert = std.debug.assert;
const c1_teeth = @import("c1_teeth.zig");
const controller = @import("controller.zig");
const job_cert = @import("job_cert.zig");
const records = @import("records.zig");
const runtime = @import("runtime.zig");
const service_cert = @import("service_cert.zig");
const sim_certs = @import("sim_certs.zig");
const store = @import("store.zig");

/// The certificate lifetime in the simulation: `workload_cert_ttl_ms` (an hour) is longer than
/// most runs, so a run would never renew. `service_cert.decide` takes the ttl as a parameter.
pub const ttl_ms: u64 = 20_000;
/// How often a supervisor that needs a certificate asks again.
pub const ask_interval_ms: u64 = 1000;
/// M3r's cut, on top of `ask_interval_ms`: the node's clock runs at its own rate (the ask times
/// are on it) and a tick is coarser than a millisecond. Far below `ttl_ms / 2`, which a supervisor
/// that renews only at expiry overruns.
pub const renew_cut_ms: u64 = 2000;
/// One tick in this many, a forged ask (per mille).
const forge_per_mille: u32 = 100;
/// The keys M6 remembers (the newest, by key number modulo this).
const keys_remembered = 1024;
/// The last key made per (node, service), by a hash: `mesh_reuse_key` hands it to a new replica.
const last_keys = 64;

comptime {
    assert(ttl_ms % 2000 == 0);
    assert(ask_interval_ms * 4 < ttl_ms / 2);
    assert((ask_interval_ms + renew_cut_ms) * 2 < ttl_ms / 2);
}

/// What M6 remembers of a certified key: the replica (by a hash of its id) and the digest.
const Certified = struct { key: u64 = 0, replica: u64 = 0, digest: [32]u8 = @splat(0) };

pub const State = struct {
    prng: std.Random.DefaultPrng,
    /// The last key number handed out; 0 is "no key".
    key_last: u64 = 0,
    asks: u32 = 0,
    issued: u32 = 0,
    /// Issues that replaced a held certificate (half-life renewals, and recoveries).
    renewed: u32 = 0,
    refused: u32 = 0,
    /// The issuer could not read a record it needs: no certificate.
    unread: u32 = 0,
    /// Certificates that expired unrenewed (ZC-W0703), and replicas back on the mesh after.
    expired: u32 = 0,
    recovered: u32 = 0,
    forged: u32 = 0,
    forged_issued: u32 = 0,
    /// The longest a judged replica went without a certificate before half-life after the heal
    /// (M3r), in simulation ms.
    due_max_ms: u64 = 0,
    /// The simulation time the faults ended (`sim_cluster.heal`); M3r is judged from then on.
    healed_at_ms: ?u64 = null,
    by_reason: [reasons]u32 = @splat(0),
    certified: [keys_remembered]Certified = @splat(.{}),
    last_key: [last_keys]u64 = @splat(0),
    /// The first of M3 and M6 to fail; the cluster's safety check reports it.
    violation: ?[]const u8 = null,

    pub fn init(seed: u64) State {
        return .{ .prng = .init(seed ^ 0xc4_ce27_0000_0003) };
    }

    fn fail(state: *State, found: []const u8) void {
        if (state.violation == null) state.violation = found;
    }

    fn key_new(state: *State) u64 {
        state.key_last += 1;
        return state.key_last;
    }
};

const refusal_names = @typeInfo(service_cert.Refusal).error_set.error_names.?;
const reasons = refusal_names.len;

fn reason_index(refusal: service_cert.Refusal) usize {
    inline for (refusal_names, 0..) |name, index| {
        if (refusal == @field(service_cert.Refusal, name)) return index;
    }
    unreachable;
}

pub fn reason_name(index: usize) []const u8 {
    return refusal_names[index];
}

pub const Outcome = union(enum) {
    issued: service_cert.Subject,
    refused: service_cert.Refusal,
    unread,
};

fn Found(comptime T: type) type {
    return struct { rec: T, kv: store.KeyValue };
}

fn get(comptime T: type, ctx: *const controller.Context, key: []const u8) ?Found(T) {
    ctx.diag.reset();
    const got = ctx.store.get(ctx.arena, key, null, ctx.diag) catch {
        ctx.diag.reset();
        return null;
    };
    const kv = got.kv orelse return null;
    const rec = records.read(T, ctx.arena, kv, ctx.diag) catch {
        ctx.diag.reset();
        return null;
    };
    return .{ .rec = rec, .kv = kv };
}

/// The server's side, as `agent_api.replica_subject` does it: `service_cert.look_up` for the
/// asking node and `service_cert.decide` over what it found. A read that fails is `unread`.
pub fn issue(ctx: *const controller.Context, id: []const u8, ask: service_cert.Ask) Outcome {
    ctx.diag.reset();
    const found = service_cert.look_up(ctx.store, ctx.arena, ask.node, id, null, ctx.diag) catch {
        ctx.diag.reset();
        return .unread;
    };
    const subject = service_cert.decide(found, ask, ttl_ms) catch |refusal|
        return .{ .refused = refusal };
    return .{ .issued = subject };
}

/// M3 and M6's first clause for a certificate just issued for replica `id` in answer to `ask`,
/// read from the same revision.
pub fn issued_problem(
    ctx: *const controller.Context,
    id: []const u8,
    ask: service_cert.Ask,
    subject: *const service_cert.Subject,
) ?[]const u8 {
    const placed = get(records.Assigned, ctx, records.assigned_key(ask.node, id).slice()) orelse
        return "M3: a certificate was issued for a replica not assigned to the node";
    if (!std.mem.eql(u8, placed.rec.service, subject.service)) {
        return "M3: a certificate names another service than the replica's";
    }
    if (ask.epoch != placed.kv.mod_revision) {
        return "M3: a certificate was issued for a stale epoch";
    }
    if (subject.placement_epoch != placed.kv.mod_revision) {
        return "M3: a certificate names another epoch than the replica's assignment";
    }
    if (!records.replica_id_valid(subject.service, id)) {
        return "M3: a certificate names a service its replica id does not belong to";
    }
    const replica_key = records.replica_key(subject.service, id);
    const replica = get(records.Replica, ctx, replica_key.slice()) orelse
        return "M3: a certificate was issued for a replica that does not exist";
    // The checker's own reading of the digest, not `job_cert`'s.
    const pinned = full_digest(replica.rec.image) orelse
        return "M6: a certificate was issued for a replica that runs no image digest";
    if (!std.mem.eql(u8, &subject.image_digest, &pinned)) {
        return "M6: a certificate names another digest than its replica's";
    }
    const lifetime = subject.lifetime;
    if (lifetime.not_after_ms -| lifetime.not_before_ms > ttl_ms) {
        return "M3: a certificate outlives the workload certificate ttl";
    }
    return null;
}

/// M6's second clause: a key certified for one replica and digest is never certified for
/// another (the new replica of a rollout makes a key of its own).
fn key_problem(state: *State, key: u64, id: []const u8, digest: [32]u8) ?[]const u8 {
    assert(key > 0);
    const slot = &state.certified[@intCast(key % keys_remembered)];
    const replica = std.hash.Wyhash.hash(0, id);
    if (slot.key == key) {
        if (slot.replica != replica) return "M6: a key was certified for two replicas";
        if (!std.mem.eql(u8, &slot.digest, &digest)) {
            return "M6: a key was certified for two digests";
        }
        return null;
    }
    slot.* = .{ .key = key, .replica = replica, .digest = digest };
    return null;
}

/// Asks for replica `id` with `key` and judges what comes back: M3 and M6 if a certificate was
/// issued.
pub fn ask_and_judge(
    state: *State,
    ctx: *const controller.Context,
    id: []const u8,
    key: u64,
    ask: service_cert.Ask,
    forged: bool,
) ?service_cert.Subject {
    state.asks += 1;
    state.forged += @intFromBool(forged);
    switch (issue(ctx, id, ask)) {
        .unread => {
            state.unread += 1;
            return null;
        },
        .refused => |refusal| {
            state.refused += 1;
            state.by_reason[reason_index(refusal)] += 1;
            return null;
        },
        .issued => |subject| {
            state.issued += 1;
            state.forged_issued += @intFromBool(forged);
            if (issued_problem(ctx, id, ask, &subject)) |found| state.fail(found);
            if (key_problem(state, key, id, subject.image_digest)) |found| state.fail(found);
            // Every counted forgery names another node, an earlier epoch or another image.
            if (forged) state.fail("M3: a forged ask got a certificate");
            return subject;
        },
    }
}

fn last_key_slot(node: []const u8, service: []const u8) usize {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(node);
    hasher.update("/");
    hasher.update(service);
    return @intCast(hasher.final() % last_keys);
}

/// The service replica a container runs, if it is one: its id (a job's run carries
/// `zcube.job`).
fn replica_of(labels: []const runtime.Label) ?[]const u8 {
    if (sim_certs.label_of(labels, runtime.label_job) != null) return null;
    return sim_certs.label_of(labels, runtime.label_replica);
}

/// One tick of every running service replica's supervisor. A replica whose certificate expired
/// goes off the mesh (ZC-W0703) and keeps running. On a node whose link to the server is not cut,
/// a replica without a certificate, or past half-life, makes a new key and asks (once per
/// `ask_interval_ms`). Then M3r, and now and then a forged ask. `nodes` and `net` are the
/// cluster's (`sim_cluster.zig`); the issuer's `now` is the asking node's clock, as in
/// `sim_certs.zig`; `true_ms` is the simulation's time, which M3r measures in.
pub fn supervise(
    state: *State,
    ctx: *const controller.Context,
    nodes: anytype,
    net: anytype,
    true_ms: u64,
) void {
    for (nodes) |node| {
        const now_ms = node.nclock.clock().now_ms();
        const faults = net.links[node.index].faults;
        const cut = faults.partition_up or faults.partition_down;
        for (node.sim.containers.containers.items) |*container| {
            if (container.phase != .running) continue;
            const id = replica_of(container.labels) orelse continue;
            const standing: service_cert.Standing = if (container.mesh_cert) |cert|
                service_cert.standing(.{
                    .not_before_ms = cert.not_before_ms,
                    .not_after_ms = cert.not_after_ms,
                }, now_ms)
            else
                .expired;
            if (standing == .expired and container.mesh_cert != null and !container.mesh_down) {
                container.mesh_down = true;
                state.expired += 1;
            }
            // `mesh_renew_late` is M3r's tooth: past half-life is still good enough.
            const waits = standing == .valid or
                (c1_teeth.mesh_renew_late and standing == .renew);
            if (!(waits or cut or now_ms < container.mesh_ask_ms)) {
                container.mesh_ask_ms = now_ms + ask_interval_ms;
                renew(state, ctx, node.name(), container, id, now_ms);
            }
            renewal_judge(state, ctx, node, container, id, cut, true_ms);
        }
    }
    forge_one(state, ctx, nodes);
}

/// M3r for one running replica, after its tick's ask: if its node is up and connected, the issuer
/// would certify it, and it holds no certificate before half-life, how long that has lasted (in
/// simulation time, from the heal at the earliest) must stay within `ask_interval_ms +
/// renew_cut_ms`. Anything else clears its clock.
fn renewal_judge(
    state: *State,
    ctx: *const controller.Context,
    node: anytype,
    container: anytype,
    id: []const u8,
    cut: bool,
    true_ms: u64,
) void {
    const healed_at_ms = state.healed_at_ms orelse {
        container.mesh_due_ms = null;
        return;
    };
    const held = if (container.mesh_cert) |cert| service_cert.standing(.{
        .not_before_ms = cert.not_before_ms,
        .not_after_ms = cert.not_after_ms,
    }, node.nclock.clock().now_ms()) == .valid else false;
    if (held or cut or node.down or !certifiable(ctx, node.name(), id, container.image)) {
        container.mesh_due_ms = null;
        return;
    }
    const since = @max(container.mesh_due_ms orelse true_ms, healed_at_ms);
    container.mesh_due_ms = since;
    const due_ms = true_ms - since;
    state.due_max_ms = @max(state.due_max_ms, due_ms);
    if (due_ms > ask_interval_ms + renew_cut_ms) {
        state.fail("M3r: a connected replica went without a certificate before half-life " ++
            "longer than the ask interval and the cut after the heal");
    }
}

/// Whether the issuer would certify replica `id` on `node` for `image` now: its assignment is
/// the node's, the replica exists, and its image is the full digest the container runs. The
/// checker's own reading, not `service_cert`'s.
fn certifiable(
    ctx: *const controller.Context,
    node: []const u8,
    id: []const u8,
    image: []const u8,
) bool {
    const placed = get(records.Assigned, ctx, records.assigned_key(node, id).slice()) orelse
        return false;
    if (placed.rec.job != null) return false;
    if (!records.replica_id_valid(placed.rec.service, id)) return false;
    const key = records.replica_key(placed.rec.service, id);
    const replica = get(records.Replica, ctx, key.slice()) orelse return false;
    if (!std.mem.eql(u8, replica.rec.image, image)) return false;
    return full_digest(image) != null;
}

/// "b3:" and 64 lowercase hex digits, read by the checker itself.
fn full_digest(image: []const u8) ?[32]u8 {
    if (!std.mem.startsWith(u8, image, "b3:")) return null;
    const hex = image["b3:".len..];
    if (hex.len != 64) return null;
    for (hex) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return null;
    }
    var digest: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, hex) catch return null;
    return digest;
}

/// One ask of a replica's supervisor, with a new key: the epoch the node's assignment holds and
/// the digest the container runs.
fn renew(
    state: *State,
    ctx: *const controller.Context,
    node: []const u8,
    container: anytype,
    id: []const u8,
    now_ms: u64,
) void {
    const placed = get(records.Assigned, ctx, records.assigned_key(node, id).slice()) orelse
        return;
    if (placed.rec.service.len == 0) return;
    const digest = job_cert.image_digest(container.image) orelse return;
    const slot = last_key_slot(node, placed.rec.service);
    // `mesh_reuse_key` is M6's tooth: a new replica takes the key last made for its service on
    // its node.
    const reused = c1_teeth.mesh_reuse_key and container.mesh_key == 0 and
        state.last_key[slot] != 0;
    const key = if (reused) state.last_key[slot] else state.key_new();
    container.mesh_key = key;
    state.last_key[slot] = key;
    const ask: service_cert.Ask = .{
        .node = node,
        .epoch = placed.kv.mod_revision,
        .image_digest = digest,
        .now_ms = now_ms,
    };
    const subject = ask_and_judge(state, ctx, id, key, ask, false) orelse return;
    if (container.mesh_cert != null) state.renewed += 1;
    if (container.mesh_down) {
        container.mesh_down = false;
        state.recovered += 1;
    }
    container.mesh_cert = .{
        .epoch = subject.placement_epoch,
        .key = key,
        .not_before_ms = subject.lifetime.not_before_ms,
        .not_after_ms = subject.lifetime.not_after_ms,
    };
}

/// The kinds of forged ask.
const Forgery = enum { stale_epoch, other_node, other_image };

fn pick(random: std.Random, len: usize) u32 {
    assert(len > 0);
    return random.uintLessThan(u32, @intCast(len));
}

/// Now and then (`forge_per_mille` of ticks), an ask made up from a service container that holds
/// a certificate: an earlier epoch, another node's name or another image, with a key of its own.
fn forge_one(state: *State, ctx: *const controller.Context, nodes: anytype) void {
    const random = state.prng.random();
    if (random.uintLessThan(u32, 1000) >= forge_per_mille) return;
    // Draws are `u32`, never `usize`: the WASM build must draw what the native one does.
    const node = nodes[pick(random, nodes.len)];
    const other = nodes[pick(random, nodes.len)];
    const items = node.sim.containers.containers.items;
    if (items.len == 0) return;
    const container = items[pick(random, items.len)];
    const id = replica_of(container.labels) orelse return;
    const cert = container.mesh_cert orelse return;
    const digest = job_cert.image_digest(container.image) orelse return;
    var ask: service_cert.Ask = .{
        .node = node.name(),
        .epoch = cert.epoch,
        .image_digest = digest,
        .now_ms = node.nclock.clock().now_ms(),
    };
    switch (random.enumValueWithIndex(Forgery, u32)) {
        .stale_epoch => {
            if (cert.epoch <= 1) return;
            ask.epoch = cert.epoch - 1 - random.uintLessThan(u64, @min(cert.epoch - 1, 1000));
        },
        .other_node => {
            if (std.mem.eql(u8, other.name(), node.name())) return;
            ask.node = other.name();
        },
        .other_image => ask.image_digest[random.uintLessThan(u32, 32)] ^= 0x5a,
    }
    _ = ask_and_judge(state, ctx, id, state.key_new(), ask, true);
}

// ---- Tests -----------------------------------------------------------------------------------

const testing = std.testing;

test "M6: a key certified for one replica and digest is refused for another" {
    var state: State = .init(1);
    const digest: [32]u8 = @splat(1);
    try testing.expectEqual(@as(?[]const u8, null), key_problem(&state, 7, "web-1", digest));
    try testing.expectEqual(@as(?[]const u8, null), key_problem(&state, 7, "web-1", digest));
    try testing.expect(key_problem(&state, 7, "web-2", digest) != null);
    try testing.expect(key_problem(&state, 7, "web-1", @splat(2)) != null);
    // Another key in the same slot replaces the memory, as the newest key is the one reused.
    const later = 7 + keys_remembered;
    try testing.expectEqual(@as(?[]const u8, null), key_problem(&state, later, "web-2", digest));
}
