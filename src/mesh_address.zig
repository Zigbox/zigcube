//! Mesh addresses (C4, docs/keys.md "Mesh addresses"): which `127.77.<hi>.<lo>` a service takes
//! when the API first writes it, and its release when the service is deleted.
//!
//! The counter `/mesh-address-next` hands out numbers in order; `/mesh-addresses/<n>` names the
//! service that holds `n`. Both are written in the apply's own transaction, each compared at the
//! revision read, so two applies that race for one number cannot both commit. Before the counter
//! wraps (65,534 creates) every number is new. After, a number is taken only if no hold names it,
//! or its hold was released at least `mesh_address_quarantine_ms` ago and no replica of the old
//! service is left: no record under `/replicas/<old>/`, no `/observed/` record of one.

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
/// ZC-E0207 if `mesh_address_probes_max` numbers in a row are all held.
pub fn assign(ctx: *const Context, batch: *controller.Batch, service: []const u8) Error![]const u8 {
    assert(records.name_problem(service, constants.service_name_bytes_max) == null);
    assert(batch.has_room(2));
    const counter = try read_counter(ctx);
    var candidate = wrapped(counter.next);
    for (0..constants.mesh_address_probes_max) |_| {
        const key = records.mesh_address_key(candidate);
        const found = try ctx.store.get(ctx.arena, key.slice(), null, ctx.diag);
        const free = if (found.kv) |kv| try reusable(ctx, kv) else true;
        if (free) {
            const held: store.Revision = if (found.kv) |kv| kv.mod_revision else 0;
            try reserve(ctx, batch, counter.mod_revision, candidate, held, service);
            const text = ctx.arena.create([constants.mesh_address_text_bytes_max]u8) catch {
                return failures.no_memory(ctx.diag);
            };
            return records.mesh_address_text(text, candidate);
        }
        candidate = wrapped(@as(u32, candidate) + 1);
    }
    return exhausted(ctx, counter.next);
}

/// Marks the hold of `address` released at the context's time, in `batch`. A hold that names
/// another service, or none, is left alone: the address was never this service's to release.
pub fn release(
    ctx: *const Context,
    batch: *controller.Batch,
    service: []const u8,
    address: []const u8,
) Error!void {
    assert(batch.has_room(1));
    const number = records.mesh_address_parse(address) orelse return;
    const key = records.mesh_address_key(number);
    const found = try ctx.store.get(ctx.arena, key.slice(), null, ctx.diag);
    const kv = found.kv orelse return;
    const hold = try records.read(records.MeshAddressHold, ctx.arena, kv, ctx.diag);
    if (!std.mem.eql(u8, hold.service, service)) return;
    if (hold.released_at_ms != null) return;
    const released: records.MeshAddressHold = .{
        .service = service,
        .released_at_ms = ctx.clock.now_ms(),
    };
    batch.expect(kv.key, kv.mod_revision);
    batch.put(kv.key, try records.encode(ctx.arena, released, ctx.diag));
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

/// Whether the hold in `kv` may be replaced: released, quarantined long enough, and no replica
/// of its service left anywhere.
fn reusable(ctx: *const Context, kv: store.KeyValue) Error!bool {
    const hold = try records.read(records.MeshAddressHold, ctx.arena, kv, ctx.diag);
    const released = hold.released_at_ms orelse return false;
    const now = ctx.clock.now_ms();
    if (now < released) return false;
    if (now - released < constants.mesh_address_quarantine_ms) return false;
    return !try replicas_remain(ctx, hold.service);
}

/// Whether any record of a replica of `service` is left: its `/replicas/<service>/` or an
/// `/observed/<node>/<service>-<n>`. An observation that does not read counts as one.
pub fn replicas_remain(ctx: *const Context, service: []const u8) Error!bool {
    assert(records.name_problem(service, constants.service_name_bytes_max) == null);
    const prefix = records.replicas_prefix(service);
    const listed = try ctx.store.list(ctx.arena, .{
        .prefix = prefix.slice(),
        .limit = 1,
    }, ctx.diag);
    if (listed.kvs.len > 0) return true;
    var skipped: u32 = 0;
    const observed = try controller.list_all_tolerant(
        records.Observed,
        ctx,
        records.prefix_observed,
        null,
        constants.replicas_max,
        &skipped,
    );
    if (skipped > 0) return true;
    for (observed.items) |*entry| {
        if (replica_of(entry.rec.replica, service)) return true;
    }
    return false;
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

fn exhausted(ctx: *const Context, next: u32) Error {
    assert(ctx.diag.code == null);
    ctx.diag.raise(.E0207);
    ctx.diag.cause("no mesh address is free: the {d} addresses from number {d} on are all " ++
        "held by services, or by deleted ones whose replicas remain or that were deleted " ++
        "within 24 hours", .{ constants.mesh_address_probes_max, wrapped(next) });
    ctx.diag.fix(.{ .sentence = "delete services that are no longer used, or wait a day" });
    return error.NoCapacity;
}
