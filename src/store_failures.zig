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
    /// Set when a node agent raises it about the server's answer (`agent_client.zig`): the
    /// agent's state directory, borrowed, which holds the file the operator removes. Null when
    /// the server raises it about its store.
    agent_state_dir: ?[]const u8 = null,
};

pub fn went_backwards(diag: *Diag, rollback: Rollback) error{BackendFailed} {
    assert(diag.code == null);
    diag.raise(.E0215);
    if (rollback.agent_state_dir) |state_dir| {
        backwards_causes(diag, rollback, agent_words);
        const look = "look at which store the server uses; to keep it as it is, run there";
        diag.fix_with(look, "zcube store accept-rollback --confirm", .{});
        const forget = "then make this agent forget its pair, and restart it";
        const file: ShellQuoted = .{ .text = state_dir, .suffix = "/remembered" };
        diag.fix_with(forget, "rm {f}", .{file});
    } else {
        backwards_causes(diag, rollback, server_words);
        const sentence = "look at which store this is; to keep it as it is, run";
        diag.fix_with(sentence, "zcube store accept-rollback --confirm", .{});
    }
    return error.BackendFailed;
}

/// `text` and `suffix` as one shell word in single quotes, a `'` inside written `'\''`, so a
/// state directory with spaces or quotes in its name pastes as it is.
const ShellQuoted = struct {
    text: []const u8,
    suffix: []const u8,

    pub fn format(quoted: ShellQuoted, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeByte('\'');
        for ([_][]const u8{ quoted.text, quoted.suffix }) |part| {
            for (part) |byte| {
                if (byte == '\'') {
                    try writer.writeAll("'\\''");
                } else {
                    try writer.writeByte(byte);
                }
            }
        }
        try writer.writeByte('\'');
    }
};

/// Who remembers, and what answered: the server about its store, or an agent about the server.
const Words = struct {
    no_hash: []const u8,
    behind: []const u8,
    forked: []const u8,
    pair_line: []const u8,
    hash_line: []const u8,
};

const server_words: Words = .{
    .no_hash = "the store has no hash for revision {d}, so it cannot be checked",
    .behind = "the store is behind: writes it acknowledged are gone",
    .forked = "the store holds a different history at that revision",
    .pair_line = "the server remembers revision {d} ({s}); the store is at revision {d} ({s})",
    .hash_line = "the server remembers revision {d} with hash {s}; the store has hash {s}",
};

const agent_words: Words = .{
    .no_hash = "the server has no hash for revision {d}, so it cannot be checked",
    .behind = "the server answered from behind: writes it acknowledged are gone",
    .forked = "the server's store holds a different history at that revision",
    .pair_line = "this agent remembers revision {d} ({s}); " ++
        "the server answered at revision {d} ({s})",
    .hash_line = "this agent remembers revision {d} with hash {s}; the server has hash {s}",
};

fn backwards_causes(diag: *Diag, rollback: Rollback, comptime words: Words) void {
    const old = short_hash(rollback.remembered_hash);
    const new = short_hash(rollback.now_hash);
    const remembered = rollback.remembered_revision;
    // The innermost cause is the one the default render shows: it carries the evidence.
    if (rollback.unverifiable) {
        diag.cause(words.no_hash, .{remembered});
        diag.cause(words.pair_line, .{ remembered, old, rollback.now_revision, new });
    } else if (rollback.now_revision < remembered) {
        diag.cause(words.behind, .{});
        diag.cause(words.pair_line, .{ remembered, old, rollback.now_revision, new });
    } else {
        diag.cause(words.forked, .{});
        diag.cause(words.hash_line, .{ remembered, old, new });
    }
}

/// The remembered pair could not be saved (`ZC-E0216`); the file is behind what the server knows.
pub fn not_saved(diag: *Diag) error{BackendFailed} {
    diag.raise(.E0216);
    diag.cause("the remembered revision could not be saved", .{});
    diag.fix(.{ .sentence = "check that the server's state directory is writable" });
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
