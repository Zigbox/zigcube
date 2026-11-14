//! Mesh addresses (C4, docs/keys.md "Mesh addresses"): which `127.77.<hi>.<lo>` a service takes
//! when the API first writes it, and its release when the service is deleted.
//!
//! The counter `/mesh-address-next` hands out numbers in order; `/mesh-addresses/<n>` names the
//! service that holds `n`. Both are written in the apply's own transaction, each compared at the
//! revision read, so two applies that race for one number cannot both commit. Before the counter
//! wraps (65,534 creates) every number is new. After, a number is taken only if no hold names it,
//! or its hold was released at least `mesh_address_quarantine_ms` ago and no replica of the old
//! service is left: no record under `/replicas/<old>/`, no `/observed/` key that names one. "The
//! old service" is the deleted incarnation: replicas numbered below the replica counter it had
//! when it was deleted (`MeshAddressHold.replicas_below`), so a service applied again under the
//! same name does not hold its old address forever (TLA+ finding 9).

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const controller = @import("controller.zig");
const records = @import("records.zig");
const store = @import("store.zig");
const failures = @import("store_failures.zig");

const Context = controller.Context;
const Error = controller.Error;

/// Reserves an address for `service` in `batch` and returns its text, in the context's arena.
/// Tries `mesh_address_probes_max` numbers (`probe_number`); ZC-E0207 if every one is held.
pub fn assign(ctx: *const Context, batch: *controller.Batch, service: []const u8) Error![]const u8 {
    assert(records.name_problem(service, constants.service_name_bytes_max) == null);
    assert(batch.has_room(2));
    const counter = try read_counter(ctx);
    const start = wrapped(counter.next);
    // Read once per create, and only when a released hold is old enough to be weighed.
    var observed: ?[]const []const u8 = null;
    for (0..constants.mesh_address_probes_max) |probe| {
        const candidate = probe_number(start, @intCast(probe));
        const key = records.mesh_address_key(candidate);
        const found = try ctx.store.get(ctx.arena, key.slice(), null, ctx.diag);
        const free = if (found.kv) |kv| try reusable(ctx, kv, &observed) else true;
        if (free) {
            const held: store.Revision = if (found.kv) |kv| kv.mod_revision else 0;
            try reserve(ctx, batch, counter.mod_revision, candidate, held, service);
            const text = ctx.arena.create([constants.mesh_address_text_bytes_max]u8) catch {
                return failures.no_memory(ctx.diag);
            };
            return records.mesh_address_text(text, candidate);
        }
    }
    return exhausted(ctx, counter.mod_revision, start);
}

const block_size: u32 = @as(u32, constants.mesh_address_max) - constants.mesh_address_min + 1;
/// Probes taken in order from the counter; the rest are spread over the whole block, so a long
/// run of held numbers after the counter does not refuse every create while most of the block
/// is free.
const probes_in_order: u32 = constants.mesh_address_probes_max / 2;
const probes_spread: u32 = constants.mesh_address_probes_max - probes_in_order;
const probe_stride: u32 = (block_size - probes_in_order) / probes_spread;

comptime {
    assert(probes_in_order > 0);
    assert(probe_stride > 1);
    // Every probe of one create is a different number: the last offset stays inside the block.
    assert(probes_in_order + (probes_spread - 1) * probe_stride < block_size);
}

/// The number a create tries at its `probe`th look, counting from the counter's `start`: the
/// first `probes_in_order` in order, then one every `probe_stride`, wrapping past the end.
pub fn probe_number(start: u16, probe: u32) u16 {
    assert(start >= constants.mesh_address_min);
    assert(start <= constants.mesh_address_max);
    assert(probe < constants.mesh_address_probes_max);
    const offset: u32 = if (probe < probes_in_order)
        probe
    else
        probes_in_order + (probe - probes_in_order) * probe_stride;
    const from_first = (@as(u32, start) - constants.mesh_address_min + offset) % block_size;
    return @intCast(constants.mesh_address_min + from_first);
}

/// Marks the hold of `address` released at the context's time, in `batch`, with the replica
/// number the deleted incarnation stops at. A hold that names another service, or none, is left
/// alone: the address was never this service's to release. `service_value` is the stored
/// service record being deleted (its C0 `next_replica` stands in for a missing counter).
pub fn release(
    ctx: *const Context,
    batch: *controller.Batch,
    service: []const u8,
    address: []const u8,
    service_value: []const u8,
) Error!void {
    assert(batch.has_room(2));
    const number = records.mesh_address_parse(address) orelse return;
    const key = records.mesh_address_key(number);
    const found = try ctx.store.get(ctx.arena, key.slice(), null, ctx.diag);
    const kv = found.kv orelse return;
    // A hold that does not read is left as it is: the delete must not fail on it, and the
    // address stays held (`reusable`).
    const hold = try read_hold(ctx, kv) orelse return;
    if (!std.mem.eql(u8, hold.service, service)) return;
    if (hold.released_at_ms != null) return;
    const below = try replicas_below(ctx, batch, service, service_value);
    const released: records.MeshAddressHold = .{
        .service = service,
        .released_at_ms = ctx.clock.now_ms(),
        .replicas_below = below,
    };
    batch.expect(kv.key, kv.mod_revision);
    batch.put(kv.key, try records.encode(ctx.arena, released, ctx.diag));
}

/// The first replica number the deleted incarnation of `service` never used: its replica
/// counter, compared in `batch` at the revision read (absent: compared as absent), so a replica
/// numbered while the delete was planned conflicts the delete instead of escaping the bound.
/// With no counter, a C0 record's `next_replica`, else 1: the replica controller creates the
/// counter before it numbers any replica.
fn replicas_below(
    ctx: *const Context,
    batch: *controller.Batch,
    service: []const u8,
    service_value: []const u8,
) Error!u64 {
    const key = records.replica_numbers_key(service);
    const key_copy = try controller.key_copy(ctx, &key);
    const found = try ctx.store.get(ctx.arena, key_copy, null, ctx.diag);
    const kv = found.kv orelse {
        batch.expect(key_copy, 0);
        return @max(1, try legacy_next_replica(ctx, service_value) orelse 1);
    };
    batch.expect(key_copy, kv.mod_revision);
    const counter = try records.read(records.ReplicaNumber, ctx.arena, kv, ctx.diag);
    return @max(1, counter.next);
}

/// A C0 service record's `next_replica`, or null: absent, or a value that does not parse.
fn legacy_next_replica(ctx: *const Context, value: []const u8) Error!?u64 {
    const Legacy = struct { next_replica: ?u64 = null };
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    const legacy = std.json.parseFromSliceLeaky(Legacy, ctx.arena, value, options) catch |err| {
        if (err == error.OutOfMemory) return failures.no_memory(ctx.diag);
        return null;
    };
    return legacy.next_replica;
}

/// The `mesh_address` a stored service value names, or null: none, or a value that does not
/// parse (a delete must not fail on it).
pub fn held_by(ctx: *const Context, value: []const u8) Error!?[]const u8 {
    const Held = struct { mesh_address: ?[]const u8 = null };
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    const held = std.json.parseFromSliceLeaky(Held, ctx.arena, value, options) catch |err| {
        if (err == error.OutOfMemory) return failures.no_memory(ctx.diag);
        return null;
    };
    return held.mesh_address;
}

const Counter = struct { next: u32, mod_revision: store.Revision };

fn read_counter(ctx: *const Context) Error!Counter {
    const found = try ctx.store.get(ctx.arena, records.key_mesh_address_next, null, ctx.diag);
    const kv = found.kv orelse return .{ .next = constants.mesh_address_min, .mod_revision = 0 };
    const counter = try records.read(records.MeshAddressNext, ctx.arena, kv, ctx.diag);
    assert(kv.mod_revision > 0);
    return .{ .next = counter.next, .mod_revision = kv.mod_revision };
}

/// `next` as an address number: past the block (or before it), the first.
pub fn wrapped(next: u32) u16 {
    if (next < constants.mesh_address_min) return constants.mesh_address_min;
    if (next > constants.mesh_address_max) return constants.mesh_address_min;
    return @intCast(next);
}

fn reserve(
    ctx: *const Context,
    batch: *controller.Batch,
    counter_revision: store.Revision,
    number: u16,
    held_revision: store.Revision,
    service: []const u8,
) Error!void {
    assert(number >= constants.mesh_address_min);
    assert(batch.has_room(2));
    const next: records.MeshAddressNext = .{ .next = @as(u32, number) + 1 };
    batch.expect(records.key_mesh_address_next, counter_revision);
    batch.put(records.key_mesh_address_next, try records.encode(ctx.arena, next, ctx.diag));
    const key = records.mesh_address_key(number);
    const key_copy = try controller.key_copy(ctx, &key);
    const hold: records.MeshAddressHold = .{ .service = service };
    batch.expect(key_copy, held_revision);
    batch.put(key_copy, try records.encode(ctx.arena, hold, ctx.diag));
}

/// The hold in `kv`, or null if it does not read (ZC-E0301, or a newer version: ZC-E0303), with
/// the diagnostic cleared: such a hold counts as held, by a service nothing can name.
fn read_hold(ctx: *const Context, kv: store.KeyValue) Error!?records.MeshAddressHold {
    return records.read(records.MeshAddressHold, ctx.arena, kv, ctx.diag) catch |err| {
        if (err != error.Malformed) return err;
        ctx.diag.reset();
        return null;
    };
}

/// Whether the hold in `kv` may be replaced: released, quarantined long enough, and no replica
/// of its service left anywhere. `observed` is read on first need and kept for the next probe.
fn reusable(
    ctx: *const Context,
    kv: store.KeyValue,
    observed: *?[]const []const u8,
) Error!bool {
    const hold = try read_hold(ctx, kv) orelse return false;
    const released = hold.released_at_ms orelse return false;
    const now = ctx.clock.now_ms();
    if (now < released) return false;
    if (now - released < constants.mesh_address_quarantine_ms) return false;
    if (observed.* == null) observed.* = try observed_replicas(ctx);
    return !try replicas_remain(ctx, hold.service, hold.replicas_below, observed.*.?);
}

/// Whether any record of a replica of the deleted incarnation of `service` is left: one under
/// `/replicas/<service>/`, or one of `observed`, the replicas `/observed/` names
/// (`observed_replicas`), numbered below `below` (null: any number). A record under
/// `/replicas/<service>/` whose key is not `<service>-<n>` counts: nothing can say it is newer.
pub fn replicas_remain(
    ctx: *const Context,
    service: []const u8,
    below: ?u64,
    observed: []const []const u8,
) Error!bool {
    assert(records.name_problem(service, constants.service_name_bytes_max) == null);
    const prefix = records.replicas_prefix(service);
    var revision: ?store.Revision = null;
    var after: ?[]const u8 = null;
    const pages_max = constants.replicas_max / constants.store_list_limit_max + 1;
    for (0..pages_max + 1) |_| {
        const page = try ctx.store.list(ctx.arena, .{
            .prefix = prefix.slice(),
            .at_revision = revision,
            .limit = constants.store_list_limit_max,
            .continue_after = after,
        }, ctx.diag);
        revision = page.revision;
        for (page.kvs) |kv| {
            const slash = std.mem.lastIndexOfScalar(u8, kv.key, '/').?;
            const replica = kv.key[slash + 1 ..];
            if (!replica_of(replica, service)) return true;
            if (of_incarnation(replica, service, below)) return true;
        }
        after = page.continue_after;
        if (after == null) break;
    } else return controller.too_many(ctx, prefix.slice(), constants.replicas_max);
    for (observed) |replica| {
        if (replica_of(replica, service) and of_incarnation(replica, service, below)) return true;
    }
    return false;
}

/// Whether `replica`, `<service>-<n>`, is numbered below `below` (null: always).
fn of_incarnation(replica: []const u8, service: []const u8, below: ?u64) bool {
    assert(replica_of(replica, service));
    const bound = below orelse return true;
    // Past nine digits `replica_number` gives up; such a number is above any counter.
    const number = records.replica_number(service, replica) orelse return false;
    return number < bound;
}

/// The replica every `/observed/<node>/<replica>` key names, from the key: a record whose value
/// does not decode still names its replica, so it holds back only its own service's address.
/// ZC-E0302 past `replicas_max`, as every reader of `/observed/`.
pub fn observed_replicas(ctx: *const Context) Error![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var revision: ?store.Revision = null;
    var after: ?[]const u8 = null;
    const pages_max = constants.replicas_max / constants.store_list_limit_max + 1;
    for (0..pages_max + 1) |_| {
        const page = try ctx.store.list(ctx.arena, .{
            .prefix = records.prefix_observed,
            .at_revision = revision,
            .limit = constants.store_list_limit_max,
            .continue_after = after,
        }, ctx.diag);
        revision = page.revision;
        for (page.kvs) |kv| {
            if (names.items.len >= constants.replicas_max) {
                return controller.too_many(ctx, records.prefix_observed, constants.replicas_max);
            }
            assert(std.mem.startsWith(u8, kv.key, records.prefix_observed));
            const slash = std.mem.lastIndexOfScalar(u8, kv.key, '/').?;
            names.append(ctx.arena, kv.key[slash + 1 ..]) catch return failures.no_memory(ctx.diag);
        }
        after = page.continue_after;
        if (after == null) return names.items;
    }
    return controller.too_many(ctx, records.prefix_observed, constants.replicas_max);
}

/// Whether `replica` is `<service>-<n>`, `n` decimal.
pub fn replica_of(replica: []const u8, service: []const u8) bool {
    if (replica.len < service.len + 2) return false;
    if (!std.mem.startsWith(u8, replica, service)) return false;
    if (replica[service.len] != '-') return false;
    for (replica[service.len + 1 ..]) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

/// Refuses the create with ZC-E0207, after moving the counter past the numbers tried in order,
/// so the next create probes other numbers rather than the same held ones (TLA+ finding 9): in a
/// transaction of its own, compared at the revision read. A conflict means another create moved
/// it; nothing else is written.
fn exhausted(ctx: *const Context, counter_revision: store.Revision, start: u16) Error {
    assert(ctx.diag.code == null);
    var batch: controller.Batch = .{};
    const moved: records.MeshAddressNext = .{ .next = probe_number(start, probes_in_order) };
    batch.expect(records.key_mesh_address_next, counter_revision);
    batch.put(records.key_mesh_address_next, try records.encode(ctx.arena, moved, ctx.diag));
    _ = try controller.commit(ctx, .api, &batch);
    ctx.diag.raise(.E0207);
    ctx.diag.cause("127.77.0.0/16 has no free address: the {d} numbers tried from number {d} " ++
        "on are all held by services, or by deleted ones whose replicas remain or that were " ++
        "deleted within 24 hours", .{ constants.mesh_address_probes_max, start });
    ctx.diag.fix(.{ .sentence = "delete services that are no longer used, or wait a day" });
    return error.NoCapacity;
}
