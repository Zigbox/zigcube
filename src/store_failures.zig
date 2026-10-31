//! The diagnostics every `Store` backend raises for the failures the contract defines
//! (`store.zig`, "Failure"). One place, so the Postgres, SQLite and memory backends word them
//! alike and a golden test of the text covers all of them. Each helper fills the `Diag` and
//! returns the matching `store.Error`, so a call site reads `return failures.compacted(...)`.
//! Backend-specific failures (a database that is busy or corrupt) stay in their backend.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");
const Diag = @import("diag.zig").Diag;
const store = @import("store.zig");

const Revision = store.Revision;

pub fn compacted(diag: *Diag, needed: Revision, compacted_revision: Revision) error{Compacted} {
    assert(diag.code == null);
    assert(needed <= compacted_revision);
    diag.raise(.E0203);
    diag.cause("history is needed from revision {d}; the store keeps it from {d}", .{
        needed, compacted_revision,
    });
    diag.fix(.{ .sentence = "list the current state and watch again from its revision" });
    return error.Compacted;
}

pub fn no_hash(diag: *Diag, asked: Revision, chain_start: Revision) error{NoHash} {
    assert(diag.code == null);
    assert(asked < chain_start);
    diag.raise(.E0214);
    diag.cause("the hash of revision {d} was asked for; the store's chain starts at {d}", .{
        asked, chain_start,
    });
    diag.cause("the store was upgraded at revision {d} from a schema without a chain", .{
        chain_start,
    });
    diag.fix(.{ .sentence = "ask for a revision at or above the start of the chain" });
    return error.NoHash;
}

pub fn future_read(diag: *Diag, asked: Revision, current: Revision) error{FutureRevision} {
    assert(diag.code == null);
    assert(asked > current);
    diag.raise(.E0204);
    diag.cause("revision {d} was asked for; the store is at {d}", .{ asked, current });
    diag.fix(.{ .sentence = "use a revision this store returned" });
    return error.FutureRevision;
}

pub fn future_watch(diag: *Diag, asked: Revision, current: Revision) error{FutureRevision} {
    assert(diag.code == null);
    assert(asked > current + 1);
    diag.raise(.E0204);
    diag.cause("a watch from revision {d} was asked for; the store is at {d}", .{
        asked, current,
    });
    diag.fix(.{ .sentence = "watch from a revision this store returned, plus one" });
    return error.FutureRevision;
}

pub fn future_compact(diag: *Diag, asked: Revision, current: Revision) error{FutureRevision} {
    assert(diag.code == null);
    assert(asked > current);
    diag.raise(.E0204);
    diag.cause("compaction to revision {d} was asked for; the store is at {d}", .{
        asked, current,
    });
    diag.fix(.{ .sentence = "compact to a revision this store returned" });
    return error.FutureRevision;
}

pub fn lease_not_found(diag: *Diag, id: store.LeaseId) error{LeaseNotFound} {
    assert(diag.code == null);
    assert(id != store.lease_none);
    diag.raise(.E0205);
    diag.cause("lease {d} is unknown, expired or revoked", .{id});
    diag.fix(.{ .sentence = "grant a new lease and register again" });
    return error.LeaseNotFound;
}

pub fn lease_keys_full(diag: *Diag, id: store.LeaseId, count: u32) error{NoCapacity} {
    assert(diag.code == null);
    assert(count > constants.store_lease_keys_max);
    diag.raise(.E0207);
    diag.cause("lease {d} would hold {d} keys; the limit is {d}", .{
        id, count, constants.store_lease_keys_max,
    });
    diag.fix(.{ .sentence = "attach fewer keys to one lease" });
    return error.NoCapacity;
}

pub fn watch_slots_full(diag: *Diag) error{NoCapacity} {
    assert(diag.code == null);
    diag.raise(.E0207);
    diag.cause("all {d} watch slots are in use", .{constants.store_watches_max});
    diag.fix(.{ .sentence = "close watches that are no longer needed" });
    return error.NoCapacity;
}

pub fn lease_slots_full(diag: *Diag) error{NoCapacity} {
    assert(diag.code == null);
    diag.raise(.E0207);
    diag.cause("all {d} lease slots are in use", .{constants.store_leases_max});
    diag.fix(.{ .sentence = "revoke leases that are no longer needed" });
    return error.NoCapacity;
}

pub fn no_memory(diag: *Diag) error{NoCapacity} {
    assert(diag.code == null);
    diag.raise(.E0207);
    diag.cause("the memory set aside for this request ran out", .{});
    diag.fix(.{ .sentence = "ask for smaller pages, or raise the request arena limit" });
    return error.NoCapacity;
}
