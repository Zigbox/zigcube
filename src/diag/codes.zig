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
    E0105,
    E0106,
    E0107,
    E0108,
    E0109,
    E0110,
    E0111,
    E0112,
    E0113,
    E0114,
    E0115,
    E0116,
    E0117,
    E0118,
    W0119,
    E0120,
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
    E0214,
    E0215,
    E0216,
    E0301,
    E0302,
    E0303,
    E0501,
    E0502,
    E0503,
    E0504,
    E0505,
    E0506,
    E0507,
    E0508,
    E0509,
    W0501,
    B0001,
    B0002,
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
        .code = .E0105,
        .severity = .@"error",
        .blame = .user,
        .summary = "the service changed while it was being applied",
        .explanation =
        \\Someone else applied or deleted the same service between the moment this
        \\request read it and the moment it tried to write. The store refused the
        \\write rather than overwrite their change. Nothing was changed.
        \\
        \\Look at the service as it is now (zcube get service), then apply again.
        ,
    },
    .{
        .code = .E0106,
        .severity = .@"error",
        .blame = .user,
        .summary = "the server's configuration can't be used",
        .explanation =
        \\zcube-server read its configuration file and flags and found a setting
        \\it cannot use: a file that is not valid ZON, an unknown setting, a store
        \\that is not memory, sqlite:<path> or postgres:<settings>, or a listen
        \\address that is not host:port. The cause line names the setting.
        \\
        \\Nothing was started. Correct the setting and start the server again.
        ,
    },
    .{
        .code = .E0107,
        .severity = .@"error",
        .blame = .environment,
        .summary = "can't listen on the server's address",
        .explanation =
        \\zcube-server could not bind its listen address: another process already
        \\holds the port, the address is not one of this machine's, or the user
        \\may not bind it (ports below 1024 need privileges).
        \\
        \\Choose another port with --listen, or stop the process that holds this
        \\one. The cause line names the address and the system's reason.
        ,
    },
    .{
        .code = .E0108,
        .severity = .@"error",
        .blame = .environment,
        .summary = "the server is at one of its limits",
        .explanation =
        \\zcube-server refused a request because it is already serving as many
        \\connections or waiting watches as it is configured to, or the request
        \\was larger than it accepts. The cause line names the limit. Nothing was
        \\changed.
        \\
        \\Try again shortly. A client that opens many watches should share one.
        ,
    },
    .{
        .code = .E0109,
        .severity = .@"error",
        .blame = .user,
        .summary = "the service file can't be read",
        .explanation =
        \\zcube apply could not read the file it was given: it does not exist, is
        \\not a regular file, is larger than a service file may be (64 KiB), or you
        \\may not read it. Nothing was sent to the server.
        \\
        \\The cause line names the path and the system's reason. Check the path, or
        \\run zcube apply from the directory that holds the file.
        ,
    },
    .{
        .code = .E0110,
        .severity = .@"error",
        .blame = .user,
        .summary = "the service file isn't valid",
        .explanation =
        \\The file is not a service written in ZON, or it names a field zcube does
        \\not know. The context line gives file:line:column of the first problem and
        \\each cause line says what is wrong there. Nothing was sent to the server.
        \\
        \\A service has .name, .image, .replicas and .command; .env and .limits are
        \\optional:
        \\
        \\    .{
        \\        .name = "hello",
        \\        .image = "b3:51aa9c03",
        \\        .replicas = 3,
        \\        .command = .{ "sh", "-c", "while true; do sleep 1; done" },
        \\    }
        ,
    },
    .{
        .code = .E0111,
        .severity = .@"error",
        .blame = .user,
        .summary = "the command line can't be understood",
        .explanation =
        \\zcube was given a command it does not have, a flag it does not know, a
        \\flag without its value, or too few or too many arguments. The cause line
        \\names the part at fault. Nothing was sent to the server.
        \\
        \\zcube help lists the commands and flags.
        ,
    },
    .{
        .code = .E0112,
        .severity = .@"error",
        .blame = .user,
        .summary = "the server address can't be used",
        .explanation =
        \\The address given with --server, or in ZCUBE_SERVER, is not an IP address
        \\(or localhost) and a port, written HOST:PORT. Nothing was sent.
        \\
        \\Without either, zcube talks to 127.0.0.1:7070, where zcube-server
        \\listens by default.
        ,
    },
    .{
        .code = .E0113,
        .severity = .@"error",
        .blame = .user,
        .summary = "apply needs an answer and there is no terminal",
        .explanation =
        \\zcube apply shows what it would change and asks before it changes
        \\anything. Its input is not a terminal, so there is nobody to ask, and it
        \\will not guess. Nothing was changed.
        \\
        \\Run it from a terminal, or give --yes to apply without being asked, as a
        \\script does. The change is still shown first.
        ,
    },
    .{
        .code = .E0114,
        .severity = .@"error",
        .blame = .user,
        .summary = "the apply was declined",
        .explanation =
        \\zcube apply showed the change and the answer was not yes. Nothing was
        \\changed on the server.
        \\
        \\Apply again and answer y, or give --yes to skip the question.
        ,
    },
    .{
        .code = .E0115,
        .severity = .@"error",
        .blame = .environment,
        .summary = "can't write the output",
        .explanation =
        \\zcube could not write its result to standard output or standard error:
        \\the descriptor is closed, the pipe has no reader, or the disk is full
        \\(for example when redirected to /dev/full). The command itself may have
        \\succeeded: an apply is not undone by this failure.
        \\
        \\Run it again with output that can be written, or check with zcube get.
        ,
    },
    .{
        .code = .E0116,
        .severity = .@"error",
        .blame = .environment,
        .summary = "can't use the state directory",
        .explanation =
        \\zcube keeps the record of its last failure and the bundles it writes in
        \\a state directory: $XDG_STATE_HOME/zcube, or $HOME/.local/state/zcube.
        \\Neither variable names an absolute path, or the directory can't be
        \\created or written. Bundles are only ever written there, never sent
        \\anywhere.
        \\
        \\Name a directory you can write, for example
        \\export XDG_STATE_HOME=$HOME/.local/state
        ,
    },
    .{
        .code = .E0117,
        .severity = .@"error",
        .blame = .user,
        .summary = "there is no failure to bundle",
        .explanation =
        \\zcube bundle --last collects the evidence for the last command of yours
        \\that failed. None is recorded in the state directory: nothing has failed
        \\yet, or the record was deleted.
        \\
        \\Name what to bundle instead: zcube bundle service <name>, or
        \\zcube bundle replica <id>.
        ,
    },
    .{
        .code = .E0118,
        .severity = .@"error",
        .blame = .user,
        .summary = "no such diagnostic code",
        .explanation =
        \\zcube explain was given a code that is not in the registry of Zigcube
        \\(ZC-) or of Zigbox (ZBX-). A code is a letter and four digits, with or
        \\without its prefix: E0201, ZC-E0201, ZBX-E0501.
        \\
        \\The index of every code is at https://zigbox.github.io/zigcube/errors/
        ,
    },
    .{
        .code = .W0119,
        .severity = .warning,
        .blame = .user,
        .summary = "--no-redact keeps secrets in the bundle",
        .explanation =
        \\Bundles replace environment values and anything that looks like a secret
        \\with [redacted:<kind>]. --no-redact turns that off, so the bundle holds
        \\them as they were. The command goes on.
        \\
        \\Read every file listed in MANIFEST.txt before you share the bundle, or
        \\leave --no-redact out. zcube never uploads a bundle.
        ,
    },
    .{
        .code = .E0120,
        .severity = .@"error",
        .blame = .environment,
        .summary = "zcube ran out of memory",
        .explanation =
        \\zcube asked for memory for an answer or a file and the system, or the
        \\limit zcube keeps on itself, said no. Nothing is lost: a command that was
        \\sending a change may or may not have been applied, so check with
        \\zcube get service before you repeat it.
        \\
        \\Ask for less (one service by name instead of all of them), or free
        \\memory on this machine.
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
        .code = .E0214,
        .severity = .@"error",
        .blame = .user,
        .summary = "the store has no chain hash for that revision",
        .explanation =
        \\Every revision the store commits gets a chain hash, which a client
        \\uses to notice a store that went backwards or forked. A store written by
        \\a zcube from before the chain existed cannot recompute the hashes of
        \\revisions it had already compacted, so its chain starts at the revision
        \\it was upgraded at, and the store has no hash for any revision below
        \\that.
        \\
        \\Ask for a revision at or above the start of the chain; the cause line
        \\names it. Nothing was changed.
        ,
    },
    .{
        .code = .E0215,
        .severity = .@"error",
        .blame = .external,
        .summary = "the store went backwards or forked",
        .explanation =
        \\The server remembers the highest revision it has seen and the chain
        \\hash of that revision. The store now answers with a lower revision,
        \\or with a different hash for the revision the server remembers, so
        \\writes the store acknowledged are gone or the history has
        \\diverged. This is what a failover to a replica that was behind, a
        \\restore from an old backup, or a store pointed at by mistake looks
        \\like. Acting on it would hand out placements and fences that
        \\contradict ones already given.
        \\
        \\The server stops: controllers do not step and every store call
        \\fails with this code until an operator looks. It never recovers by
        \\itself. Look at the store (which database, which replica, which
        \\backup). If the rolled-back or forked store is the one to keep, run
        \\zcube store accept-rollback --confirm, which makes the server
        \\remember the store as it is now. The old and new revision and hash are
        \\shown in the reply of that command; a decision record that keeps them
        \\is not written yet.
        ,
    },
    .{
        .code = .E0216,
        .severity = .@"error",
        .blame = .external,
        .summary = "the remembered revision file is unusable",
        .explanation =
        \\The server keeps the highest store revision and chain hash it has
        \\seen in a small file in its state directory, so that a restart after
        \\a lossy failover still notices that the store went backwards
        \\(ZC-E0215). The file could not be read, is not what the server
        \\wrote, or could not be written. A file that does not parse stops the
        \\start: the server does not guess. A save that fails while the server
        \\runs does not stop it, but the file then lags behind what the server
        \\knows, and a crash in that time forgets the difference; the failure
        \\is shown once in the log and in GET /v1/status.
        \\
        \\Check the state directory (--state-dir) and its permissions. If the
        \\file is damaged and the store is the one to trust, delete the file;
        \\the server then remembers the store as it finds it.
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
        .code = .E0303,
        .severity = .@"error",
        .blame = .environment,
        .summary = "a stored record is from a newer release",
        .explanation =
        \\A value in the store carries a format version this release does not know:
        \\a newer zcube wrote it, and this one is older. The value is not
        \\malformed, so nothing was changed and nothing was skipped; this release
        \\just cannot say what the newer fields mean, and acting on a half-read
        \\record could undo the newer release's work.
        \\
        \\The cause line names the key and both versions. Run the release that
        \\wrote the record, or upgrade this one; if you downgraded on purpose,
        \\restore the store from the backup taken before the upgrade.
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
        .code = .E0503,
        .severity = .@"error",
        .blame = .environment,
        .summary = "the agent can't reach zcube-server",
        .explanation =
        \\The agent asked zcube-server for its replicas or told it what it saw, and
        \\the connection failed: the server is down, the address in the agent's
        \\configuration is wrong, or the network between them is broken.
        \\
        \\Workloads keep running while the server is away: each runs under a
        \\supervisor of its own. The agent retries with a growing pause and reports
        \\once when the server is back. Check that the server is up and that
        \\--server names its address.
        ,
    },
    .{
        .code = .E0504,
        .severity = .@"error",
        .blame = .external,
        .summary = "zcube-server refused the agent's request",
        .explanation =
        \\zcube-server answered the agent with an error it does not expect, or with
        \\a reply the agent cannot read. The cause line carries the server's own
        \\diagnostic. The server and the agent are probably different versions,
        \\or something between them is answering in the server's place.
        \\
        \\Use the agent that came with the server. The agent retries; nothing it
        \\runs is stopped meanwhile.
        ,
    },
    .{
        .code = .E0505,
        .severity = .@"error",
        .blame = .user,
        .summary = "the agent's configuration can't be used",
        .explanation =
        \\A flag or a setting in the agent's ZON file is missing, unknown or out of
        \\range, or the image fixtures file it names cannot be read. The cause
        \\line names the setting. The agent did not start and changed nothing.
        \\
        \\Run zcube-agent --help for the flags and the file's fields.
        ,
    },
    .{
        .code = .E0506,
        .severity = .@"error",
        .blame = .environment,
        .summary = "the agent's state directory can't be used",
        .explanation =
        \\The agent keeps one directory per container, holding the container's
        \\spec, the run record its supervisor writes and the lock that shows the
        \\supervisor is alive. The directory could not be created or read, or
        \\another agent is using it.
        \\
        \\Check the path and its permissions, and that only one agent uses it. The
        \\cause line names the path and what the host reported.
        ,
    },
    .{
        .code = .E0507,
        .severity = .@"error",
        .blame = .environment,
        .summary = "the agent can't start a container's supervisor",
        .explanation =
        \\Each container runs under a supervisor, the agent's own executable started
        \\again. The host refused to start it: no process slots, no memory, or the
        \\executable is gone. The container was not started.
        \\
        \\The cause line says what the host reported. Free process slots or restart
        \\the agent from its installed executable; the controller retries.
        ,
    },
    .{
        .code = .E0508,
        .severity = .@"error",
        .blame = .user,
        .summary = "the container's command can't be run",
        .explanation =
        \\The supervisor could not execute the replica's command: the program was
        \\not found on the node, is not executable, or is not a program. Nothing
        \\of the workload ran.
        \\
        \\Check the command in the service file. The replica is held, not retried:
        \\a new one would fail the same way. Apply the corrected file to replace it.
        ,
    },
    .{
        .code = .E0509,
        .severity = .@"error",
        .blame = .environment,
        .summary = "the container's supervisor is gone",
        .explanation =
        \\The container's supervisor process ended without writing a run record,
        \\so nobody knows how the command ended: it was killed, or the host
        \\restarted. The agent stops any process of the container that is left,
        \\and the controller starts a replacement.
        \\
        \\If this repeats, look for something killing zcube-agent processes (an
        \\out-of-memory killer, a cleanup job) on the node.
        ,
    },
    .{
        .code = .W0501,
        .severity = .warning,
        .blame = .environment,
        .summary = "the agent's lease ended and it registered again",
        .explanation =
        \\The agent could not renew its lease in time, so the store deleted the
        \\node's registration. The agent granted a new lease and registered again.
        \\Its workloads keep running: stopping them when a node is cut off is
        \\planned for a later milestone.
        \\
        \\This happens when the agent was paused or cut off from the server for
        \\longer than the lease time to live.
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
    .{
        .code = .B0002,
        .severity = .bug,
        .blame = .internal,
        .summary = "zcube failed in a way it should not",
        .explanation =
        \\A step of zcube stopped with an error that its own code is supposed to
        \\handle before it reaches you. This is a bug in zcube, not something you
        \\did, and the command may or may not have taken effect: check with
        \\zcube get.
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
