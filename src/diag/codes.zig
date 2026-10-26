//! The Zigcube diagnostic registry: every `ZC-` code, declared once (DIAGNOSTICS.md, "Codes").
//!
//! A code is an enum tag, so naming one that is not declared does not compile. The `comptime`
//! block fails the build if the registry and the enum disagree, if a tag has the wrong kind
//! letter for its severity, if blame and severity contradict each other, or if a summary or an
//! explanation is missing or malformed. This is a stub: only the codes that the `Store` and
//! `Runtime` contracts raise are here. `zcube explain`, the docs pages and the golden tests
//! arrive with C0 proper.
//!
//! Numbering: `01xx` API and CLI, `02xx` store backends, `03xx` controllers, `04xx` scheduler,
//! `05xx` agent, `06xx` distribution, `07xx` mesh, `08xx` trust. A code is never reused or
//! renumbered. Zigbox's `ZBX-` codes are a separate registry (see docs/diagnostics-plan.md).

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("../constants.zig");
const text_util = @import("../text.zig");
const zigbox = @import("zigbox");

pub const Severity = zigbox.codes.Severity;

/// Whose problem it is. This decides the exit code (see `exit_code`).
pub const Blame = zigbox.codes.Blame;

/// Every code, in registry order: `registry[i].code` is the i-th tag. The tag is the part of the
/// code after "ZC-": a kind letter (E error, W warning, B bug) and four digits.
pub const Code = enum(u8) {
    E0101,
    E0102,
    E0103,
    E0104,
    E0201,
    E0202,
    E0203,
    E0204,
    E0205,
    E0206,
    E0207,
    E0208,
    E0209,
    E0210,
    E0211,
    E0212,
    E0213,
    E0301,
    E0302,
    E0501,
    E0502,
    B0001,
};

pub const Entry = struct {
    code: Code,
    severity: Severity,
    blame: Blame,
    /// One line, present tense, no trailing period. Fixed per code: what varies goes in causes.
    summary: []const u8,
    /// Printed by `zcube explain`: what it means, why it happens, what to do. Hard-wrapped.
    explanation: []const u8,
};

pub const registry = [_]Entry{
    .{
        .code = .E0101,
        .severity = .@"error",
        .blame = .user,
        .summary = "no such resource",
        .explanation =
        \\The API was asked for a service, replica or node that does not exist, or
        \\for a path it does not serve. Nothing was changed.
        \\
        \\List what exists with zcube get service, or check the name for a typo.
        \\A deleted service keeps its decision history for a day, so zcube why can
        \\still explain a recent deletion.
        ,
    },
    .{
        .code = .E0102,
        .severity = .@"error",
        .blame = .environment,
        .summary = "can't reach zcube-server",
        .explanation =
        \\A client (the zcube command or the web console) could not complete a
        \\request to zcube-server: it is down, unreachable from this machine, or a
        \\proxy dropped the connection. This code is raised by the client, so it
        \\never appears in the server's logs.
        \\
        \\Workloads keep running while the server is away. Check that the server is
        \\up and that the address in the client's configuration is right.
        ,
    },
    .{
        .code = .E0103,
        .severity = .@"error",
        .blame = .environment,
        .summary = "zcube-server sent a reply the client can't read",
        .explanation =
        \\The reply was not JSON, or lacked the fields the API promises. This code
        \\is raised by the client. The server and the client are probably
        \\different versions.
        \\
        \\Use the client that came with the server, or upgrade whichever is older.
        ,
    },
    .{
        .code = .E0104,
        .severity = .@"error",
        .blame = .user,
        .summary = "the request can't be understood",
        .explanation =
        \\The request used a method the endpoint does not accept, or a query
        \\parameter that is repeated, unknown, malformed or out of range, or a
        \\request ID that is not 8 to 64 letters, digits and hyphens. The cause
        \\line names the part at fault. Nothing was changed.
        \\
        \\The read-only API answers GET only. See docs/api.md for the parameters
        \\of each endpoint.
        ,
    },
    .{
        .code = .E0201,
        .severity = .@"error",
        .blame = .external,
        .summary = "can't reach the store backend",
        .explanation =
        \\The control-plane store (Postgres or SQLite) did not answer. The server
        \\and every controller read and write desired state through it, so nothing
        \\can be reconciled while it is down. Workloads already running on nodes
        \\keep running.
        \\
        \\Check that the database is up and that the connection settings in the
        \\server's configuration are right, then retry. The cause line names the
        \\backend and what it reported.
        ,
    },
    .{
        .code = .E0202,
        .severity = .@"error",
        .blame = .external,
        .summary = "the store backend failed an operation",
        .explanation =
        \\The store backend was reachable but refused or failed a read or a write
        \\(a full disk, a lock timeout, a schema that does not match this version).
        \\The operation did not take effect; the store never applies half of a
        \\transaction.
        \\
        \\The cause line carries the backend's own message. Fix the condition it
        \\names and retry.
        ,
    },
    .{
        .code = .E0203,
        .severity = .@"error",
        .blame = .user,
        .summary = "that revision was compacted away",
        .explanation =
        \\The store keeps history only back to its compaction point. A read or a
        \\watch asked for a revision older than that, so the events in between can
        \\no longer be replayed.
        \\
        \\A client that follows changes (a controller, an agent) recovers by
        \\listing the current state and watching again from the revision the list
        \\returns. A person asking for an old revision with --at-revision should
        \\ask for a newer one.
        ,
    },
    .{
        .code = .E0204,
        .severity = .@"error",
        .blame = .user,
        .summary = "that revision does not exist yet",
        .explanation =
        \\A read or a watch named a revision higher than the store's current one.
        \\Revisions only count up, one per committed write; a future revision is
        \\a mistake in the caller, usually a revision copied from another store.
        \\
        \\Use a revision returned by this store.
        ,
    },
    .{
        .code = .E0205,
        .severity = .@"error",
        .blame = .environment,
        .summary = "the lease has expired or was revoked",
        .explanation =
        \\A lease holds keys alive for as long as its owner keeps renewing it. This
        \\one is gone: it ran out of time (the owner could not reach the store in
        \\time) or someone revoked it. The keys attached to it were deleted.
        \\
        \\A node agent that sees this has lost its place in the cluster. It stops
        \\its workloads, grants a new lease and registers again.
        ,
    },
    .{
        .code = .E0206,
        .severity = .@"error",
        .blame = .user,
        .summary = "the request exceeds a store limit",
        .explanation =
        \\Keys, values, transactions and result pages have fixed upper bounds. The
        \\request went over one of them: a key or value that is too long, a
        \\transaction with too many operations, or a lease with a time to live
        \\outside the allowed range.
        \\
        \\The cause line names the limit and its value. Shorten or split the
        \\request.
        ,
    },
    .{
        .code = .E0207,
        .severity = .@"error",
        .blame = .environment,
        .summary = "the store has no free capacity for this",
        .explanation =
        \\The store is full in a dimension it bounds on purpose: all watch slots
        \\are in use, all lease slots are in use, or the memory set aside for the
        \\request was not enough for the result.
        \\
        \\Close watches that are no longer needed, or ask for smaller pages. If the
        \\limit is too low for the fleet, raise it in the server's configuration.
        ,
    },
    .{
        .code = .E0208,
        .severity = .@"error",
        .blame = .environment,
        .summary = "the store database is busy",
        .explanation =
        \\Another process or connection held a lock the store needed and did not
        \\let go within the time zcube waits, or Postgres ended the operation
        \\because it conflicted with another (a deadlock or a serialisation
        \\failure). The operation did not take effect.
        \\
        \\Only the zcube server should use a store while it runs. Look for a
        \\second server, a backup job or a manual sqlite3 or psql session that
        \\holds a transaction open on the same store, stop it, and retry. On
        \\Postgres, a long-running transaction in pg_stat_activity is the usual
        \\cause.
        ,
    },
    .{
        .code = .E0209,
        .severity = .@"error",
        .blame = .external,
        .summary = "the store database is damaged or not a store",
        .explanation =
        \\What zcube opened as its store is not a usable zcube store: a SQLite file
        \\that is corrupt, truncated or of another kind (or empty and not meant to
        \\be initialised), or a Postgres schema that holds other tables, lacks
        \\zcube's own, or has lost one of them.
        \\
        \\Restore from a backup, or point the server at a different file or
        \\schema. To start with an empty store, move the SQLite file aside, or
        \\name a schema that does not exist yet, and let the server create it.
        \\Nothing was changed.
        ,
    },
    .{
        .code = .E0210,
        .severity = .@"error",
        .blame = .user,
        .summary = "the store database is from a newer zcube",
        .explanation =
        \\The store was written by a newer version of zcube, whose schema this
        \\version does not understand. It refuses to touch the store rather than
        \\risk damaging it.
        \\
        \\Run the zcube version that created the file, or upgrade this one. The
        \\cause line names both schema versions. Nothing was changed.
        ,
    },
    .{
        .code = .E0211,
        .severity = .@"error",
        .blame = .user,
        .summary = "the store backend refused the credentials",
        .explanation =
        \\Postgres was reachable but would not let zcube in: the password or the
        \\role in the connection settings is wrong, or the server's pg_hba.conf
        \\has no rule that admits this role from this host. Nothing can be read
        \\or written until it does.
        \\
        \\Check the user and password in the server's store settings against
        \\what Postgres has (psql with the same settings shows the same error),
        \\or ask the database administrator for a pg_hba.conf rule. The first
        \\cause line carries Postgres's own message.
        ,
    },
    .{
        .code = .E0212,
        .severity = .@"error",
        .blame = .user,
        .summary = "the store database does not exist",
        .explanation =
        \\Postgres is up and accepted the connection, but the database named in
        \\the store settings does not exist on that server (or this role may not
        \\connect to it). zcube creates its tables, never the database itself.
        \\
        \\Create the database, or correct its name in the settings. The cause
        \\line names it. Nothing was changed.
        ,
    },
    .{
        .code = .E0213,
        .severity = .@"error",
        .blame = .external,
        .summary = "the store connection dropped during an operation",
        .explanation =
        \\The connection to Postgres ended while an operation was in progress: the
        \\server restarted or was stopped, a backend was terminated, or the
        \\network between them failed. zcube reconnects before the next
        \\operation, but cannot retry this one.
        \\
        \\If the cause line says nothing was changed, the operation was rolled
        \\back. If it says the outcome is unknown, the connection dropped while
        \\the commit was in flight and the write may or may not have been
        \\applied: read the keys again before repeating it.
        ,
    },
    .{
        .code = .E0301,
        .severity = .@"error",
        .blame = .external,
        .summary = "a stored record can't be read",
        .explanation =
        \\A controller, the agent or the API read a value from the store that is
        \\not a record of the kind its key says: not JSON, a field of the wrong
        \\type, or a name that breaks the naming rules. The API validates what it
        \\writes, so something else wrote this key, or the store was edited by hand.
        \\
        \\The cause line names the key. Fix or delete that key (zcube get shows
        \\it); the controller skips nothing silently and tries again on its next
        \\pass.
        ,
    },
    .{
        .code = .E0302,
        .severity = .@"error",
        .blame = .environment,
        .summary = "there is more to reconcile than one pass holds",
        .explanation =
        \\A controller pass reads every service and replica, and each kind has a
        \\fixed upper bound so that a pass fits its memory. The store holds more
        \\than that, so the pass stopped before changing anything it could not
        \\see whole.
        \\
        \\The cause line names the bound. Delete services that are no longer
        \\needed; if the fleet really is this large, the bound is a constant in
        \\src/constants.zig and the next release raises it.
        ,
    },
    .{
        .code = .E0501,
        .severity = .@"error",
        .blame = .environment,
        .summary = "the runtime does not know that container",
        .explanation =
        \\The agent asked the runtime about a container by name and the runtime has
        \\no record of it. The agent starts every container itself and re-adopts the
        \\ones it finds after a restart, so this means the runtime's state directory
        \\was emptied or replaced while the agent was running.
        \\
        \\The workload is treated as lost and the controller starts a replacement.
        \\Check that nothing else is cleaning the agent's state directory.
        ,
    },
    .{
        .code = .E0502,
        .severity = .@"error",
        .blame = .environment,
        .summary = "the runtime failed an operation",
        .explanation =
        \\The runtime could not carry out a request that is not about one workload's
        \\image or command: listing its containers, stopping one, reading its state
        \\directory, or running out of the slots it provisions at startup.
        \\
        \\The cause line names the operation and what the host reported. A failure
        \\to start one workload is not this code: it is reported on that workload,
        \\with the runtime's own diagnostic.
        ,
    },
    .{
        .code = .B0001,
        .severity = .bug,
        .blame = .internal,
        .summary = "zcube hit an internal error",
        .explanation =
        \\An invariant that zcube relies on did not hold. This is a bug in zcube,
        \\not something you did.
        \\
        \\A diagnostic bundle is saved for every bug. Review its manifest, then
        \\attach it to a report at https://github.com/Zigbox/zigcube/issues/new.
        ,
    },
};

/// The longest tag: a kind letter and four digits.
const tag_bytes: u32 = 5;
const prefix = "ZC-";

comptime {
    const fields = std.meta.fieldNames(Code);
    // One entry per tag, in tag order: this is what makes a duplicate or a missing entry a
    // build error, and lets `entry` index the table directly.
    assert(registry.len == fields.len);
    assert(fields.len <= std.math.maxInt(u8));
    assert(prefix.len + tag_bytes <= constants.diag_code_bytes_max);
    @setEvalBranchQuota(100_000);
    for (registry, fields, 0..) |item, name, index| {
        assert(@backingInt(item.code) == index);
        assert(std.mem.eql(u8, @tagName(item.code), name));
        check_entry(item);
    }
}

/// Compile-time validation of one entry. Split out so each rule reads on its own line.
fn check_entry(item: Entry) void {
    comptime {
        const tag = @tagName(item.code);
        assert(tag.len == tag_bytes);
        for (tag[1..]) |digit| assert(std.ascii.isDigit(digit));
        // The kind letter and the severity say the same thing.
        switch (item.severity) {
            .@"error" => assert(tag[0] == 'E'),
            .warning => assert(tag[0] == 'W'),
            .bug => assert(tag[0] == 'B'),
            .note => unreachable, // Notes carry no code letter; none is registered.
        }
        // A bug is ours; anything ours is a bug.
        assert((item.blame == .internal) == (item.severity == .bug));
        check_summary(item.summary);
        check_explanation(item.explanation);
    }
}

fn check_summary(summary: []const u8) void {
    comptime {
        assert(summary.len > 0);
        assert(summary.len <= constants.diag_summary_bytes_max);
        assert(summary[summary.len - 1] != '.');
        assert(summary[0] != ' ');
        assert(summary[summary.len - 1] != ' ');
        for (summary) |byte| assert(text_util.is_printable(byte));
    }
}

fn check_explanation(explanation: []const u8) void {
    comptime {
        assert(explanation.len > 0);
        assert(explanation.len <= constants.diag_explanation_bytes_max);
        assert(explanation[explanation.len - 1] != '\n');
        var lines = std.mem.splitScalar(u8, explanation, '\n');
        while (lines.next()) |line| {
            assert(line.len <= constants.diag_explanation_line_bytes_max);
            for (line) |byte| assert(text_util.is_printable(byte));
        }
    }
}

pub fn entry(code: Code) *const Entry {
    const index = @backingInt(code);
    assert(index < registry.len);
    const found = &registry[index];
    assert(found.code == code); // Pair assertion with the comptime check above.
    return found;
}

/// The exit code a failure of this blame ends the process with. The only place that decides.
pub fn exit_code(blame: Blame) u8 {
    const code: u8 = switch (blame) {
        .user => constants.exit_user,
        .environment => constants.exit_environment,
        .external => constants.exit_external,
        .internal => constants.exit_internal,
    };
    assert(code != constants.exit_ok);
    return code;
}

const full_names = blk: {
    const fields = std.meta.fieldNames(Code);
    var names: [fields.len][]const u8 = undefined;
    for (fields, 0..) |name, index| names[index] = prefix ++ name;
    break :blk names;
};

/// "ZC-E0201". Comptime-built, so it is a static string.
pub fn full_name(code: Code) []const u8 {
    const name = full_names[@backingInt(code)];
    assert(std.mem.startsWith(u8, name, prefix));
    assert(name.len == prefix.len + tag_bytes);
    return name;
}

/// Finds a code from what a user typed: "E0201", "ZC-E0201", in any letter case. Anything else
/// (another product's prefix, extra characters, an unregistered number) is null.
pub fn parse(text: []const u8) ?Code {
    var rest = text;
    if (rest.len >= prefix.len) {
        if (std.ascii.eqlIgnoreCase(rest[0..prefix.len], prefix)) rest = rest[prefix.len..];
    }
    if (rest.len != tag_bytes) return null;
    for (registry) |item| {
        if (std.ascii.eqlIgnoreCase(rest, @tagName(item.code))) return item.code;
    }
    return null;
}

test "every registered code round-trips through its names" {
    // Goal: full_name and parse are inverse for every code, and the table is indexed by tag.
    for (registry) |item| {
        try std.testing.expect(entry(item.code).code == item.code);
        try std.testing.expectEqual(item.code, parse(@tagName(item.code)).?);
        try std.testing.expectEqual(item.code, parse(full_name(item.code)).?);
    }
    try std.testing.expectEqualStrings("ZC-E0201", full_name(.E0201));
    try std.testing.expectEqualStrings("ZC-B0001", full_name(.B0001));
}

test "parse refuses near misses and the other product's prefix" {
    // Goal: the boundary where an argument stops being a code. "zcube explain" must not
    // explain the wrong code, so anything but an exact tag is null.
    try std.testing.expectEqual(Code.E0201, parse("e0201").?);
    try std.testing.expectEqual(Code.E0201, parse("zc-E0201").?);
    try std.testing.expect(parse("") == null);
    try std.testing.expect(parse("ZC-") == null);
    try std.testing.expect(parse("E021") == null);
    try std.testing.expect(parse("E02011") == null);
    try std.testing.expect(parse("E9999") == null);
    try std.testing.expect(parse("ZBX-E0201") == null);
    try std.testing.expect(parse(" E0201") == null);
}

test "blame decides the exit code, and every blame has a distinct one" {
    try std.testing.expectEqual(@as(u8, 1), exit_code(.user));
    try std.testing.expectEqual(@as(u8, 2), exit_code(.environment));
    try std.testing.expectEqual(@as(u8, 3), exit_code(.external));
    try std.testing.expectEqual(@as(u8, 70), exit_code(.internal));
}
