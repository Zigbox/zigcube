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

/// The first four bytes of a chain hash in hex: enough to tell two apart in a diagnostic.
pub const ShortHash = [8]u8;

pub fn short_hash(hash: store.Hash) ShortHash {
    return std.fmt.bytesToHex(hash[0..4].*, .lower);
}

/// What the store answered where the server remembered `remembered`: `now` is the store's
/// revision and hash at the same revision (or at its head when it is behind). `unverifiable` is
/// set when the store cannot say what its hash was at the remembered revision, because that is
/// below the point its chain starts at (`ZC-E0214`): the server fails closed.
pub const Rollback = struct {
    remembered_revision: Revision,
    remembered_hash: store.Hash,
    now_revision: Revision,
    now_hash: store.Hash,
    unverifiable: bool = false,
};

pub fn went_backwards(diag: *Diag, rollback: Rollback) error{BackendFailed} {
    assert(diag.code == null);
    diag.raise(.E0215);
    const old = short_hash(rollback.remembered_hash);
    const new = short_hash(rollback.now_hash);
    // The innermost cause is the one the default render shows: it carries the evidence.
    if (rollback.unverifiable) {
        diag.cause("the store has no hash for revision {d}, so it cannot be checked", .{
            rollback.remembered_revision,
        });
        diag.cause("the server remembers revision {d} ({s}); the store is at revision {d} ({s})", .{
            rollback.remembered_revision, old, rollback.now_revision, new,
        });
    } else if (rollback.now_revision < rollback.remembered_revision) {
        diag.cause("the store is behind: writes it acknowledged are gone", .{});
        const line = "the server remembers revision {d} ({s}); the store is at revision {d} ({s})";
        diag.cause(line, .{ rollback.remembered_revision, old, rollback.now_revision, new });
    } else {
        diag.cause("the store holds a different history at that revision", .{});
        diag.cause("the server remembers revision {d} with hash {s}; the store has hash {s}", .{
            rollback.remembered_revision, old, new,
        });
    }
    const sentence = "look at which store this is; to keep it as it is, run";
    diag.fix_with(sentence, "zcube store accept-rollback --confirm", .{});
    return error.BackendFailed;
}

/// The remembered revision file could not be read, parsed or written (`store_verified.zig`).
pub fn remembered_unusable(
    diag: *Diag,
    path: []const u8,
    action: []const u8,
    reason: []const u8,
) error{BackendFailed} {
    assert(diag.code == null);
    diag.raise(.E0216);
    diag.cause("can't {s} {s}: {s}", .{ action, path, reason });
    diag.fix(.{ .sentence = "check the state directory (--state-dir) and its permissions" });
    return error.BackendFailed;
}
