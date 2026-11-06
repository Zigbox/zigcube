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
    E0121,
    E0122,
    E0123,
    E0124,
    E0130,
    E0131,
    E0132,
    E0133,
    E0134,
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
    E0307,
    W0307,
    W0308,
    E0401,
    E0402,
    E0403,
    E0404,
    E0501,
    E0502,
    E0503,
    E0504,
    E0505,
    E0506,
    E0507,
    E0508,
    E0509,
    E0510,
    E0511,
    E0512,
    E0513,
    E0514,
    E0515,
    E0521,
    E0522,
    E0523,
    W0501,
    W0503,
    W0504,
    E0601,
    W0601,
    W0602,
    W0603,
    E0801,
    E0802,
    E0803,
    E0804,
    E0805,
    E0806,
    E0807,
    E0808,
    E0809,
    E0810,
    E0811,
    E0812,
    E0813,
    E0814,
    E0815,
    E0816,
    E0817,
    E0818,
    E0819,
    E0820,
    B0001,
    B0002,
    B0003,
    B0004,
    B0005,
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
        .summary = "a file named on the command line can't be read",
        .explanation =
        \\zcube could not read a file the command names: the service file of
        \\zcube apply, or the input file of zcube job run. It does not exist, is
        \\not a regular file, or you may not read it, or zcube would need more
        \\memory than it may use to read it. Nothing was sent to the server.
        \\
        \\The cause line names the path and the system's reason. Check the path, or
        \\run zcube from the directory that holds the file.
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
        \\
        \\zcube local keeps its database, logs and containers in a directory of its
        \\own, $ZCUBE_LOCAL_DIR if that is set, else the local directory under the
        \\state directory above. The same applies: it must be absolute, and zcube
        \\must be able to create and write it. If ZCUBE_LOCAL_DIR is set, change or
        \\unset that one instead; XDG_STATE_HOME does not affect it.
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
        \\without its prefix: E0201, ZC-E0201, ZBX-E0410.
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
        .code = .E0121,
        .severity = .@"error",
        .blame = .user,
        .summary = "the lease settings cannot fence an agent in time",
        .explanation =
        \\An agent that loses contact with the server stops its containers a fixed
        \\margin before its lease can run out, and the server places replacements
        \\only after the lease has run out and a grace period has passed. The
        \\margin must cover the time the agent needs to stop its containers, the
        \\drift between the two clocks over one lease, and the time the kernel
        \\needs to kill a process. These settings leave too little, so two copies
        \\of a replica could run at once.
        \\
        \\The cause line names the numbers. Shorten the lease time to live, or
        \\leave the fencing constants as they are.
        ,
    },
    .{
        .code = .E0122,
        .severity = .@"error",
        .blame = .environment,
        .summary = "zcube local can't find or start the server or agent",
        .explanation =
        \\zcube local up starts zcube-server and zcube-agent, and looks for them in
        \\the directory that holds the zcube command itself. One of them is not
        \\there, is not an executable file, or the system refused to start it, so
        \\nothing was left running.
        \\
        \\Build all three with zig build and run zcube from zig-out/bin, or keep the
        \\three files together when you install them.
        ,
    },
    .{
        .code = .E0123,
        .severity = .@"error",
        .blame = .environment,
        .summary = "the local server or agent did not come up",
        .explanation =
        \\zcube local up started zcube-server and zcube-agent, but the server did
        \\not answer, or the node did not register, within the time zcube waits.
        \\Both processes were stopped again. The cause line says which of the two
        \\steps failed, and the server's own log, which names the real reason (a
        \\port in use, a database it could not open), is in the local directory.
        \\
        \\Read server.log and agent.log there. Your data is kept: zcube local up
        \\tries again with the same files.
        ,
    },
    .{
        .code = .E0124,
        .severity = .@"error",
        .blame = .environment,
        .summary = "another zcube local command is running",
        .explanation =
        \\zcube local up and zcube local down take turns: each holds a lock on the
        \\file lock in the local directory while it starts or stops the server and
        \\the agent, so two of them never fight over the same processes. Another one
        \\held the lock for longer than this one was willing to wait.
        \\
        \\Wait for the other command to finish and run this one again. The lock is
        \\released when its holder ends, however it ends, so it is never stale.
        ,
    },
    .{
        .code = .E0130,
        .severity = .@"error",
        .blame = .user,
        .summary = "a job is not valid",
        .explanation =
        \\`zcube job run`, or a POST to /v1/jobs, named a job that cannot run as it
        \\stands. The cause line names the field and the limit it broke: a name that
        \\is not 1 to 48 bytes of lowercase letters, digits and hyphens (none at
        \\either end), or the name `watch`, which /v1/jobs/watch reserves, no
        \\command or too many words, a deadline of zero or above 24 hours, a grace
        \\period above 60 seconds, env above 8 KiB, an input above 64 KiB or with a
        \\NUL byte, a submit time more than an hour ahead, or
        \\more labels than a job may carry.
        \\
        \\Two fields are refused because they are not built yet, and the cause says
        \\so: retries above 0 (a job runs at most once), and relay or placement.
        \\Accepting a field and ignoring it would say something false about where the
        \\job runs.
        \\
        \\Fix the field it names and submit again.
        ,
    },
    .{
        .code = .E0131,
        .severity = .@"error",
        .blame = .user,
        .summary = "a different job already has that name",
        .explanation =
        \\A job named this exists, and what you submitted differs from it in its
        \\image, source, command, env, limits, deadline, grace period, labels, retries
        \\or input. Submitting the same job again is safe and changes nothing: the
        \\second POST answers with the job that exists. A different job is refused so
        \\that a retry can never replace the one that ran.
        \\
        \\Use another name, or wait until the old job has ended and been removed (an
        \\ended job is kept for at least an hour), then submit again.
        ,
    },
    .{
        .code = .E0132,
        .severity = .@"error",
        .blame = .user,
        .summary = "there are too many jobs",
        .explanation =
        \\The cluster holds as many jobs as it accepts: either the jobs not yet ended
        \\have reached their bound, or too many jobs were created in the last 73
        \\hours, the longest an ended job can still be kept. The cause line says which
        \\bound and its value. The job was not created.
        \\
        \\Wait for jobs to end, or cancel the ones you no longer need
        \\(zcube job cancel), and submit again. Ended jobs are removed by age, after
        \\at least an hour; nothing here removes them sooner.
        ,
    },
    .{
        .code = .E0133,
        .severity = .@"error",
        .blame = .user,
        .summary = "no job by that name",
        .explanation =
        \\No job with this name is stored. Either it never existed, or it ended and
        \\was removed: an ended job is kept for at least an hour and at most a day.
        \\
        \\zcube job list shows the jobs that exist. A client that watches endings must
        \\record each one it has handled; a job it has not seen end may be gone.
        ,
    },
    .{
        .code = .E0134,
        .severity = .@"error",
        .blame = .user,
        .summary = "the time to submit this job has passed",
        .explanation =
        \\Every job is submitted with a submit-by time, at most an hour ahead. This
        \\POST arrived after it, so the job was not created. The deadline exists so
        \\that a retry of a POST can always find the job the first one made: an ended
        \\job is kept for at least as long as a submit window.
        \\
        \\Submit again with a new submit-by time. If the job was created by an
        \\earlier attempt, zcube job get NAME shows it; do not assume it did not run.
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
        \\
        \\An agent raises it too: it remembers the highest revision and hash
        \\the server's answers carried, and refuses an answer from behind them.
        \\After accept-rollback on the server, remove the file remembered in
        \\the agent's state directory and restart the agent.
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
        \\
        \\An agent raises it too, about the file remembered in its own state
        \\directory, which holds the highest revision and hash the server's
        \\answers carried and the server address they came from. A file the
        \\agent cannot read, or did not write, stops its start; one written
        \\by a newer zcube-agent says so. A save that fails while the agent
        \\runs does not stop it: it warns once, naming the file, and tries
        \\again. If the file is damaged, delete it and restart the agent; it
        \\then remembers the server as it finds it.
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
        .code = .E0307,
        .severity = .@"error",
        .blame = .external,
        .summary = "a job's stored records contradict each other",
        .explanation =
        \\The records of one job (its desired state, its run, its status and what its
        \\node reported) do not agree: a run with no job, a status that has ended and
        \\carries no ending, an ending that does not match its state. The API writes
        \\them together and validates what it writes, so something else wrote one of
        \\the keys, or the store was edited by hand.
        \\
        \\The cause line names the job and the keys. The job controller changes
        \\nothing for that job until it is fixed.
        \\
        \\Never fix it by deleting the job's run (/job-runs/NAME) or its status
        \\(/job-status/NAME) alone. A job that lost its run could be started a
        \\second time, and its ending lost; the controller refuses to create a run
        \\for a job that had one, and changes nothing. Restore the missing or
        \\damaged record, or, to remove the whole job, delete all of its keys in
        \\one transaction: /jobs/NAME, /job-input/NAME, /job-runs/NAME,
        \\/job-status/NAME and /job-observed/NODE/NAME.
        ,
    },
    .{
        .code = .W0307,
        .severity = .warning,
        .blame = .environment,
        .summary = "a report for an ended job was dropped",
        .explanation =
        \\An agent reported on a run whose job had already ended. A job's ending is
        \\written once and never changes, so the report was not applied; it is
        \\recorded in the job's decisions so that it can be seen.
        \\
        \\This is normal after a node was cut off and came back: the control plane
        \\ended the job as unreachable, and the agent then reported what it had
        \\done. zcube why job NAME shows both.
        ,
    },
    .{
        .code = .W0308,
        .severity = .warning,
        .blame = .user,
        .summary = "a job waits: no node can take it now",
        .explanation =
        \\The scheduler placed nothing for this job yet. Either no node has the CPU,
        \\memory or room it asks for, or every node already holds the most jobs it
        \\may. The job stays pending and is looked at again whenever a node or an
        \\assignment changes.
        \\
        \\A job that is not started within its deadline ends as failed (deadline).
        \\Lower its limits, add a node, or wait for a job to end. zcube why job NAME
        \\names the shortfall.
        ,
    },
    .{
        .code = .E0401,
        .severity = .@"error",
        .blame = .user,
        .summary = "a repair needs confirming",
        .explanation =
        \\zcube repair allocations rewrites a node's allocation record, the
        \\scheduler's accounting of what is placed there, with the total rebuilt
        \\from the node's assignments. It changes authoritative state, so it runs
        \\only when asked twice: the cause line says what it would write, and
        \\nothing was changed.
        \\
        \\Look at zcube check allocations first. If the rebuilt total is right,
        \\run the same command again with --confirm.
        ,
    },
    .{
        .code = .E0402,
        .severity = .@"error",
        .blame = .user,
        .summary = "the node has no open allocation finding",
        .explanation =
        \\A node's allocation record is repaired only while the allocation auditor
        \\has an open finding on it: the finding is the evidence the repair cites.
        \\This node has none, so its accounting agreed with its assignments when
        \\last audited, or the node is not known. Nothing was changed.
        \\
        \\Run zcube check allocations to see every node's accounting.
        ,
    },
    .{
        .code = .E0403,
        .severity = .@"error",
        .blame = .user,
        .summary = "the node's accounting changed during the repair",
        .explanation =
        \\The repair read a node's assignments and allocation record, and before
        \\it could write the rebuilt total the scheduler placed or released a
        \\replica there, or the auditor changed its finding. It tried again a few
        \\times and the accounting kept moving, so nothing was written.
        \\
        \\Run the command again. zcube check allocations shows whether the node
        \\still needs it.
        ,
    },
    .{
        .code = .E0404,
        .severity = .@"error",
        .blame = .user,
        .summary = "a node's accounting disagrees with its assignments",
        .explanation =
        \\zcube check allocations rebuilt each node's allocation from its
        \\assignments and found at least one node whose allocation record says
        \\otherwise. The table on standard output shows both totals; the command
        \\exits 1 so that a script notices. Nothing was changed.
        \\
        \\A disagreement is a bug (ZC-B0003, which the allocation auditor records
        \\on the node). While it stands the scheduler places nothing on that node.
        \\Collect a bundle of the node, then repair its accounting with zcube
        \\repair allocations <node>, which says what it would write.
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
        .code = .E0510,
        .severity = .@"error",
        .blame = .environment,
        .summary = "the agent's tenure on its node has ended",
        .explanation =
        \\An agent writes what it observed only while it holds tenure on its node:
        \\while the node's registration is the one it made. This write named a
        \\registration that has since ended or been replaced, because the lease
        \\ran out or another registration took its place. Nothing was written.
        \\
        \\The agent stops its containers, registers again and reports from the
        \\new tenure. Nothing needs doing unless this repeats: then two agents
        \\may be using one node name, or the agent is cut off for longer than
        \\the lease time to live.
        ,
    },
    .{
        .code = .E0511,
        .severity = .@"error",
        .blame = .user,
        .summary = "the image does not give the tree the service names",
        .explanation =
        \\The node pulled the image from the reference it has for this tree, and
        \\the files it unpacked to are not the tree the service's image digest
        \\names. Nothing was started.
        \\
        \\Either the reference points at another image than the one the digest
        \\was made from, or the digest was made for another platform (the node's
        \\architecture decides which image of a multi-platform reference it gets).
        \\Pull the reference again with Zigbox, take the tree digest it prints and
        \\put that in the service file.
        ,
    },
    .{
        .code = .E0512,
        .severity = .@"error",
        .blame = .environment,
        .summary = "the node can't apply limits: no user systemd bus",
        .explanation =
        \\The service sets a CPU, memory or process limit. Zigbox applies limits
        \\through a cgroup scope that the user's systemd creates, and the agent's
        \\user has no systemd user bus (no login session, or lingering is off).
        \\The container was not started: running it without its limits would
        \\not be what the service asked for.
        \\
        \\Enable lingering for the agent's user (loginctl enable-linger) and make
        \\sure XDG_RUNTIME_DIR names its runtime directory, or remove the limits.
        ,
    },
    .{
        .code = .E0513,
        .severity = .@"error",
        .blame = .environment,
        .summary = "this host can't run Zigbox containers",
        .explanation =
        \\The agent was started with --runtime zigbox on a host that can't run
        \\rootless containers: Zigbox needs cgroup v2, user namespaces, uidmap
        \\and the other things its doctor checks. The agent did not start.
        \\
        \\Run zbx doctor as the agent's user; it names each missing piece and how
        \\to fix it. Use --runtime fake for a node that only runs test workloads.
        ,
    },
    .{
        .code = .E0514,
        .severity = .@"error",
        .blame = .user,
        .summary = "the service does not fit Zigbox's limits",
        .explanation =
        \\The replica's name, command or environment is longer than Zigbox keeps
        \\in a run record. The container was not started.
        \\
        \\The cause line says which. Shorten it in the service file and apply the
        \\file again; the replica is held, not retried.
        ,
    },
    .{
        .code = .E0515,
        .severity = .@"error",
        .blame = .environment,
        .summary = "a swarm fetch outlived its kill, so the image was not pulled",
        .explanation =
        \\A replica's image was being fetched from peers into this node's Zigbox
        \\store, the fetch passed its deadline (or ended badly), and the supervisor
        \\killed the fetch's whole process group with SIGKILL. A process of that
        \\group was still alive afterwards. It may still be writing the store, and
        \\Zigbox's store takes one writer at a time, so the supervisor did not
        \\start the registry pull: the replica was not started.
        \\
        \\A process that outlives SIGKILL is in uninterruptible sleep, waiting on
        \\the kernel: usually a disk or a network mount that stopped answering.
        \\Find it (ps -eo pid,stat,wchan:32,args, state D) and the device it waits
        \\on. The replica is started again on a later pass once it is gone.
        ,
    },
    .{
        .code = .E0521,
        .severity = .@"error",
        .blame = .environment,
        .summary = "the agent could not tell how a run ended",
        .explanation =
        \\A run's container is gone and nothing says how it ended: the agent lost its
        \\state directory or the supervisor's exit record, or the host restarted, so
        \\the process that was running it no longer exists and left no exit status.
        \\
        \\The job ends as failed (unknown). It is never started again: a run is
        \\started at most once, and starting it to find out would break that. The
        \\cause line names the run and what was missing.
        \\
        \\Find out why: a host restart (uptime, the system log) or a state directory
        \\that was cleared, moved or not mounted (the agent's --state-dir). Fix that
        \\first, or the next run can be lost the same way; then submit the job again
        \\under a new name if it should run.
        ,
    },
    .{
        .code = .E0522,
        .severity = .@"error",
        .blame = .environment,
        .summary = "a run's start record is missing or damaged",
        .explanation =
        \\Before a run is started the agent writes a record of it in its state
        \\directory, so that after a crash it can tell a run it has started from one
        \\it has not. This record was missing, or could not be read.
        \\
        \\The agent does not guess: it starts nothing it cannot prove it has not
        \\started. The run is reported as lost and its job ends as failed (unknown).
        \\Check the state directory's disk and permissions.
        ,
    },
    .{
        .code = .E0523,
        .severity = .@"error",
        .blame = .environment,
        .summary = "a run's input does not match its digest",
        .explanation =
        \\A job that was submitted with an input stores the input once and names it
        \\in the run by its SHA-256 digest. The agent fetched the input after it
        \\claimed the run and checked it against that digest. Either the server
        \\holds no input for the run, or what it holds does not hash to the digest.
        \\
        \\The API wrote both the run and the input, so this is a damaged or edited
        \\store, or a bug in Zigcube, never something the job's author did. The
        \\agent starts nothing it cannot verify: the run ends as failed
        \\(start_failed) and is not started again. A fetch that fails for any
        \\other reason, such as a network error, is not this: it is tried again.
        \\
        \\Report it with the diagnostic bundle, then submit the job again.
        ,
    },
    .{
        .code = .W0501,
        .severity = .warning,
        .blame = .environment,
        .summary = "the agent fenced itself and registered again",
        .explanation =
        \\The agent could not renew its lease in time, or the server said its
        \\lease or tenure had ended. It stopped every container, so that nothing
        \\runs on this node that the cluster may have placed elsewhere, then
        \\granted a new lease and registered again with nothing running.
        \\
        \\This happens when the agent was paused or cut off from the server for
        \\longer than the lease time to live less the fencing margin.
        ,
    },
    .{
        .code = .W0503,
        .severity = .warning,
        .blame = .user,
        .summary = "a job reached its deadline and was stopped",
        .explanation =
        \\A job ran for as long as its deadline allows, counted from the moment it
        \\started on this node's clock. The agent asked the process to stop, waited
        \\for the job's grace period, and then killed it. The job ends as failed
        \\(deadline).
        \\
        \\Raise the deadline, at most 24 hours, if the job needs the time; a job that
        \\should be faster is a job to look at.
        ,
    },
    .{
        .code = .W0504,
        .severity = .warning,
        .blame = .environment,
        .summary = "a pull record was not stored",
        .explanation =
        \\A fetch or a pull on this node finished, but the record of what
        \\it moved (the bytes by source, which /v1/stats/pull shows) was
        \\lost. It could not be written to the container's directory, or
        \\the agent read it and dropped it because it was not a pull
        \\record for this node, or zcube-server refused it; the cause line
        \\says which. The image is not affected and the replica goes on;
        \\only the statistics are missing.
        \\
        \\The agent drops a record it cannot store so that one bad file
        \\never blocks the ones after it. If the cause is a refusal, use
        \\the agent that came with the server. If it is the state
        \\directory, check its disk space and permissions.
        ,
    },
    .{
        .code = .E0601,
        .severity = .@"error",
        .blame = .external,
        .summary = "a tree could not be fetched from any peer or the registry",
        .explanation =
        \\A node needed the chunk tree of an image and could not get it onto this
        \\node: no peer sent it, and the registry did not serve it. The cause line
        \\names the tree's digest and every source that was tried, in order.
        \\
        \\Check that the registry is reachable from this node, and that the digest
        \\names an image that was pushed. A digest that was never pushed is held by
        \\no source, so every fetch of it fails the same way.
        ,
    },
    .{
        .code = .W0601,
        .severity = .warning,
        .blame = .external,
        .summary = "a peer sent a chunk that does not match its hash",
        .explanation =
        \\A node that was asked for a chunk of an image sent bytes whose hash is not
        \\the chunk's. The chunk was dropped and the node asked for no more from
        \\that peer during this fetch; it came from another peer or the registry.
        \\
        \\The image is not affected: nothing is stored or run before every chunk
        \\matches. The peer's disk or store may be damaged, or it may be running a
        \\different build; check that node.
        ,
    },
    .{
        .code = .W0602,
        .severity = .warning,
        .blame = .external,
        .summary = "a peer's chunk list does not match its digest",
        .explanation =
        \\A node that was asked for an image's chunk tree got a list from a peer
        \\whose BLAKE3 digest is not the tree's digest. The list was ignored and the
        \\node tried the next source: another peer, then the registry.
        \\
        \\The image is not affected: a tree is used only when its digest matches.
        \\No action is needed. If it repeats, check the peer node, whose store may
        \\be damaged or running a different build.
        ,
    },
    .{
        .code = .W0603,
        .severity = .warning,
        .blame = .environment,
        .summary = "the swarm fetch ended without the tree",
        .explanation =
        \\The supervisor of a replica tried to get the image's chunk tree from peers
        \\first, and that fetch ended without it: it did not start, it exited with a
        \\failure, or it was killed at its deadline. The cause line says which.
        \\The registry pull follows, so the replica can still start; this line
        \\only explains why the peers did not supply the tree.
        \\
        \\The fetch's own diagnostic, in the same fetch.log, names the real
        \\reason when it had one (ZC-E0601 for a tree no peer could give, or the
        \\code of this node's disk or memory failing). If the replica did not
        \\start, the pull's own diagnostic follows it. If it repeats on every
        \\start, check the peers and the network between them.
        ,
    },
    .{
        .code = .E0801,
        .severity = .@"error",
        .blame = .external,
        .summary = "a peer's credential is not signed by this cluster",
        .explanation =
        \\A node presented a credential that the cluster's certificate authority
        \\did not sign: its key id is not this cluster's, or its signature does not
        \\verify. The connection was closed before anything was exchanged.
        \\
        \\The control plane is the authority. A node gets its credential when its
        \\agent joins (POST /v1/agent/nodes/<node>/credential). A node that never
        \\joined, or joined a different cluster, is refused by every peer.
        \\
        \\Check that the node's agent talks to this cluster's server, and that its
        \\ca.pub in the agent state directory is the one this server serves. Deleting
        \\the agent's peer.cred makes it join again.
        ,
    },
    .{
        .code = .E0802,
        .severity = .@"error",
        .blame = .external,
        .summary = "a peer's credential is expired or not yet valid",
        .explanation =
        \\A node presented a credential outside its validity window, judged on this
        \\machine's wall clock with a skew allowance of 60 seconds. A credential lives
        \\24 hours and the agent renews it after half that.
        \\
        \\The usual causes are a node whose clock is far off, or an agent that
        \\could not reach the server for a day. Check the clock on both machines
        \\(timedatectl). The agent renews by itself, on start and at half the life,
        \\and retries every few seconds when the server refuses.
        ,
    },
    .{
        .code = .E0803,
        .severity = .@"error",
        .blame = .external,
        .summary = "the peer is not the node that was asked for",
        .explanation =
        \\A client connected to a node's peer address and the credential the server
        \\presented names a different node. The client closed the connection before it
        \\sent its own credential.
        \\
        \\This happens when a node's address in /nodes/<node> is stale and another
        \\node now answers there. It resolves itself when the agent re-registers;
        \\check zcube get nodes for the address.
        ,
    },
    .{
        .code = .E0804,
        .severity = .@"error",
        .blame = .external,
        .summary = "a peer handshake failed",
        .explanation =
        \\The handshake between two nodes ended before it finished: a message was
        \\malformed, cut short or altered, a signature over the exchange did not
        \\verify, the peer spoke another protocol version, or a key was unusable. A
        \\server that refuses a client closes the connection without a reply, so a
        \\refusal and a network cut look alike from the client's side.
        \\
        \\Nothing was transferred. If it repeats between two particular nodes, compare
        \\their clocks and their credentials (the agent's peer.cred), and look for the
        \\server's own line naming the refusal. The handshake is interim; see
        \\docs/peer.md.
        ,
    },
    .{
        .code = .E0805,
        .severity = .@"error",
        .blame = .external,
        .summary = "a peer record was refused",
        .explanation =
        \\A record on an established peer connection failed authentication: it was
        \\altered, repeated, dropped or reordered, or it was longer than allowed,
        \\or the connection reached its record limit. The connection was closed.
        \\
        \\Whatever was in flight is discarded and fetched again, from this peer or
        \\another. Image data is checked by its hash regardless. A single
        \\occurrence on a flaky network is harmless; a pattern between two nodes
        \\points at the path between them.
        ,
    },
    .{
        .code = .E0806,
        .severity = .@"error",
        .blame = .user,
        .summary = "a peer key or trust file can't be used",
        .explanation =
        \\The server's CA key (ca*.key in its state directory), the list of removed
        \\nodes (revoked), or an agent's node key (peer.key), credential (peer.cred)
        \\or trusted CA key (ca.pub) could not be read, created, written or parsed,
        \\or its file or directory has permissions that let other users read a secret
        \\or write a trust file. Key files must be owned by the process, mode 0600,
        \\and hold one line of 64 hex digits; the state directory must not be
        \\writable by group or others. A revoked line must be a node name.
        \\
        \\The secret is never printed. If the file is damaged and there is a backup,
        \\put it back. An agent's files are caches: it ignores a damaged peer.cred
        \\or ca.pub and joins again by itself; delete peer.key to get a new node key.
        \\A server whose CA key is missing although its store has run refuses to
        \\start: put the key back, or start once with --new-ca to make a new CA on
        \\purpose (every agent then joins again by itself).
        ,
    },
    .{
        .code = .E0807,
        .severity = .@"error",
        .blame = .user,
        .summary = "a node was refused a credential: it was removed",
        .explanation =
        \\The server will not issue or renew a peer credential for this node,
        \\because its name is on the server's list of removed nodes (the revoked
        \\file in its state directory). The node's current credential stays valid
        \\until it expires, within a day, and then its peers refuse it.
        \\
        \\If the node should be in the cluster, remove its name from the revoked
        \\file and restart zcube-server; the agent asks again by itself. The API is
        \\unauthenticated, so this binds an honest node only: until the API has auth,
        \\anyone who can reach it can register a name and ask for a credential.
        ,
    },
    .{
        .code = .E0808,
        .severity = .@"error",
        .blame = .external,
        .summary = "a peer's handshake was refused: its address is over a limit",
        .explanation =
        \\An agent's peer server limits what one source address may ask of it,
        \\because a handshake costs the server public-key work. A handshake is
        \\refused, and the connection closed without a byte, when the address
        \\already has peer_handshakes_pending_per_source_max handshakes that
        \\have not finished, when it has started peer_handshakes_per_source_max
        \\handshakes in peer_handshake_window_ms, or when the server already
        \\tracks peer_sources_max addresses in the window. An IPv6 address
        \\counts by its /64, one host's whole range.
        \\
        \\The cause names the refused address (an IPv6 one by its /64). The
        \\text is shown once per peer_refusal_log_ms, not once per connection.
        \\An honest fetch opens a handful of connections and keeps
        \\them. If one node is refused over and over, something there retries
        \\in a loop: look at its agent's output. A refused node tries again by
        \\itself, and a fetch falls back to the registry meanwhile. A flood
        \\from many addresses can fill the table and turn honest nodes away
        \\for up to one window; no action is needed unless it repeats.
        ,
    },
    .{
        .code = .E0809,
        .severity = .@"error",
        .blame = .external,
        .summary = "a certificate is malformed or outside the bounds",
        .explanation =
        \\A certificate was refused before its signature was looked at. Zigcube reads
        \\X.509 v3 strictly: DER only, Ed25519 only, a lifetime within the bound, at
        \\most x509_cert_bytes_max bytes. A certificate of this cluster also has one
        \\commonName, the extensions of its kind in a fixed order and a SPIFFE ID of
        \\the form spiffe://<cluster>/service/<name> (or one DNS name for a server).
        \\A server certificate under a pinned anchor of another CA may carry any
        \\names, key identifiers and extension order, but no unknown critical
        \\extension, no extension twice, and one DNS name or SPIFFE ID (docs/mtls.md).
        \\
        \\The cause names the field and the rule it broke. A certificate that the
        \\cluster CA issued does not break any; if one does, it did not come from
        \\zcube (another CA, a hand-made file) or it was damaged on the way.
        \\
        \\Ask for a new certificate from the cluster CA, or from the anchor's CA with
        \\the profile docs/mtls.md describes.
        ,
    },
    .{
        .code = .E0810,
        .severity = .@"error",
        .blame = .external,
        .summary = "a certificate is not signed by the pinned anchor",
        .explanation =
        \\The certificate's issuer is not this cluster's CA, or its signature does
        \\not verify under the pinned anchor key.
        \\
        \\Only certificates signed directly by the one pinned key are accepted: no
        \\chain, no intermediate. The check comes before the validity window, so a
        \\forged certificate is never reported as expired.
        \\
        \\Check that both sides were given the same cluster CA, and that the
        \\certificate was issued after the last --new-ca. A certificate issued by an
        \\earlier CA must be replaced.
        ,
    },
    .{
        .code = .E0811,
        .severity = .@"error",
        .blame = .external,
        .summary = "a certificate is expired or not yet valid",
        .explanation =
        \\The certificate is signed by the pinned anchor but the current time is
        \\outside its validity window, allowing peer_clock_skew_ms of clock difference
        \\on each side. The signature was checked first, so the certificate is
        \\genuine. The cause shows notBefore, notAfter and this machine's time.
        \\
        \\Check the clocks on both machines. A workload certificate lives for the
        \\service's deadline, at most x509_leaf_ttl_ms_max: ask for a new one.
        ,
    },
    .{
        .code = .E0812,
        .severity = .@"error",
        .blame = .external,
        .summary = "a certificate names another server than the one asked for",
        .explanation =
        \\The server's certificate verified against the pinned anchor, but the name
        \\in its subjectAltName is not the name the connection was made to. Names are
        \\compared exactly: no wildcard, no case folding. The cause shows both names.
        \\
        \\Connect to the name the certificate is for, or issue the server a
        \\certificate for the name in the configuration.
        ,
    },
    .{
        .code = .E0813,
        .severity = .@"error",
        .blame = .external,
        .summary = "a TLS handshake was refused",
        .explanation =
        \\The peer's handshake message was malformed, came in the wrong order, held
        \\a signature or Finished that does not verify, or the peer sent a fatal
        \\alert. Nothing was accepted: the connection is closed and no application
        \\data was sent. The cause names the message and the rule, or the alert the
        \\peer sent.
        \\
        \\A signature or Finished that does not verify means the peer does not hold
        \\the key of the certificate it showed, or the two sides saw different
        \\handshakes. Check that the peer is a zcube server and that nothing between
        \\the two rewrites the connection.
        ,
    },
    .{
        .code = .E0814,
        .severity = .@"error",
        .blame = .external,
        .summary = "the TLS client certificate was not asked for, or was refused",
        .explanation =
        \\The client was told to present a certificate and the server did not ask
        \\for one, or the server refused the one presented (the alert names why:
        \\bad_certificate, certificate_expired, unknown_ca, certificate_required).
        \\A client that sends an empty Certificate (it has no certificate, or the
        \\request does not list Ed25519) and is refused by the server is this too,
        \\and so is a client that must authenticate facing a request without
        \\Ed25519. The connection is closed; a refusal arrives after the client's
        \\own handshake is done, so data written before the alert was read was
        \\not accepted.
        \\
        \\A server that never asks cannot learn which workload is calling, so a
        \\connection that must prove identity stops. Check that the server is
        \\configured to require client certificates and trusts the cluster CA;
        \\a refused certificate is expired, issued by another CA, or for a
        \\different workload than the server allows. A signer that fails is a
        \\different error (ZC-E0820).
        ,
    },
    .{
        .code = .E0815,
        .severity = .@"error",
        .blame = .external,
        .summary = "a TLS record failed its checks",
        .explanation =
        \\A record was too long, too short, did not authenticate, or the connection
        \\reached the end of what its keys may protect. The connection is closed and
        \\the keys are wiped.
        \\
        \\On a healthy network this does not happen: it means bytes were changed in
        \\transit, the peer is not speaking TLS 1.3, or a peer sent more than 2^24
        \\records without updating its keys. Reconnect; if it repeats, check the path
        \\between the two machines.
        ,
    },
    .{
        .code = .E0816,
        .severity = .@"error",
        .blame = .external,
        .summary = "a TLS connection ended or stalled without close_notify",
        .explanation =
        \\The peer's side of the connection ended before it sent close_notify, so the
        \\data received may be cut short. Mid-handshake this means the peer hung up
        \\before the handshake finished.
        \\
        \\The connection also ends this way when the peer stays connected and goes
        \\quiet: a handshake, or the answer to a KeyUpdate, did not finish in time
        \\because the peer stopped reading or answering. A black hole, an overloaded
        \\server or a middlebox that drops packets looks like this.
        \\
        \\Treat what arrived as incomplete and retry the request. A peer that
        \\crashes, or a network that resets the connection, ends this way; for a
        \\stall, check that the server is reachable and keeping up.
        ,
    },
    .{
        .code = .E0817,
        .severity = .@"error",
        .blame = .user,
        .summary = "an identity could not be issued",
        .explanation =
        \\A workload or server certificate was not made because its request breaks a
        \\bound: more labels than x509_labels_max, a label key or value over its limit
        \\or with a character that is not allowed, label keys not sorted and unique,
        \\labels together over x509_labels_bytes_max, a cluster or service name that
        \\does not make a SPIFFE ID spiffe://<cluster>/service/<name>, a DNS name that
        \\is not lowercase, has a wildcard or an all-digit label, or a lifetime that
        \\is empty or over x509_leaf_ttl_ms_max (x509_ca_ttl_ms_max for a CA), or a
        \\subject key that is not a valid Ed25519 public key (off the curve, or in a
        \\small subgroup), which no honest holder has.
        \\
        \\The cause names the rule. Correct the request and issue again; nothing was
        \\written.
        ,
    },
    .{
        .code = .E0818,
        .severity = .@"error",
        .blame = .external,
        .summary = "a TLS peer needs something zcube does not offer",
        .explanation =
        \\zcube speaks TLS 1.3 only, with x25519, TLS_AES_128_GCM_SHA256 and Ed25519
        \\signatures, and offers no resumption and no retry. The peer answered with
        \\an older protocol version, another suite, group or signature scheme, or a
        \\HelloRetryRequest. The cause names which.
        \\
        \\Peers of a zcube cluster are zcube servers. If this is not one, connect to
        \\the right address; there is no setting that widens what zcube offers.
        ,
    },
    .{
        .code = .E0819,
        .severity = .@"error",
        .blame = .external,
        .summary = "a certificate is of another kind than this use needs",
        .explanation =
        \\The certificate is genuine and well formed, but it is not for this use: a
        \\workload's client certificate presented as a server's, a CA certificate
        \\presented as a leaf, or, under a foreign anchor, a certificate whose
        \\extended key usage lacks serverAuth or whose basic constraints say CA.
        \\
        \\The cause names the kind found and the kind needed. Give the peer a
        \\certificate issued for its role: a server certificate for a server.
        ,
    },
    .{
        .code = .E0820,
        .severity = .@"error",
        .blame = .environment,
        .summary = "the key behind the client certificate did not sign",
        .explanation =
        \\The server asked for a client certificate and the client has one, but the
        \\signer that holds its private key returned no signature, so the proof of
        \\possession (CertificateVerify) could not be made. The connection is
        \\closed with an internal_error alert; nothing was accepted.
        \\
        \\The key never enters the TLS client: it sits behind a signer, in the same
        \\process or in another. This is that signer failing, not the server or the
        \\certificate. Check that the process or device holding the key is running
        \\and reachable, then reconnect.
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
    .{
        .code = .B0003,
        .severity = .bug,
        .blame = .internal,
        .summary = "allocation accounting disagrees with assignments",
        .explanation =
        \\The allocation auditor rebuilt a node's allocation from its assignments
        \\and found a total that differs from the node's allocation record. Every
        \\transaction that places or releases a replica updates that record, so a
        \\difference can only come from a defect in zcube, never from the
        \\environment. The auditor records a finding and never repairs it: while
        \\the finding is open the scheduler places nothing on the node, but it
        \\still releases.
        \\
        \\Run zcube check allocations to see both totals. If the rebuilt one is
        \\right, zcube repair allocations <node> --confirm writes it. Please
        \\report it at https://github.com/Zigbox/zigcube/issues/new with the
        \\output of zcube why node <node>.
        ,
    },
    .{
        .code = .B0004,
        .severity = .bug,
        .blame = .internal,
        .summary = "zcube could not map how a job ended",
        .explanation =
        \\The job controller read an end of a run (an exit, a stop cause and what the
        \\agent reported) that none of its rules covers. The job is left as it was;
        \\nothing was ended or started. This is a bug in zcube, not something you
        \\did.
        \\
        \\A diagnostic bundle is saved for every bug. Review its manifest, then
        \\attach it to a report at https://github.com/Zigbox/zigcube/issues/new.
        ,
    },
    .{
        .code = .B0005,
        .severity = .bug,
        .blame = .internal,
        .summary = "a job's run record is larger than a run may be",
        .explanation =
        \\The record of a job's run, once encoded, is larger than the bound on one
        \\run (16 KiB). The API checks a job's words against their bounds before it
        \\accepts the job, so a job that reaches this point got past a check it
        \\should have failed. This is a bug in zcube, not something you did, and
        \\not a memory limit: raising limits changes nothing. The job is not started.
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
    // The check walks every byte of every summary and explanation (about 4 branches a byte).
    @setEvalBranchQuota(registry.len * (constants.diag_explanation_bytes_max +
        constants.diag_summary_bytes_max) * 8);
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
