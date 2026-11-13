// Generated from src/diag/codes.zig by web/mock/gen-codes.mjs. Do not edit by hand.
export const ZC_CODES = [
  {
    "code": "ZC-E0101",
    "severity": "error",
    "blame": "user",
    "summary": "no such resource",
    "explanation": "The API was asked for a service, replica or node that does not exist, or\nfor a path it does not serve. Nothing was changed.\n\nList what exists with zcube get service, or check the name for a typo.\nA deleted service keeps its decision history for a day, so zcube why can\nstill explain a recent deletion."
  },
  {
    "code": "ZC-E0102",
    "severity": "error",
    "blame": "environment",
    "summary": "can't reach zcube-server",
    "explanation": "A client (the zcube command or the web console) could not complete a\nrequest to zcube-server: it is down, unreachable from this machine, or a\nproxy dropped the connection. This code is raised by the client, so it\nnever appears in the server's logs.\n\nWorkloads keep running while the server is away. Check that the server is\nup and that the address in the client's configuration is right."
  },
  {
    "code": "ZC-E0103",
    "severity": "error",
    "blame": "environment",
    "summary": "zcube-server sent a reply the client can't read",
    "explanation": "The reply was not JSON, or lacked the fields the API promises. This code\nis raised by the client. The server and the client are probably\ndifferent versions.\n\nUse the client that came with the server, or upgrade whichever is older."
  },
  {
    "code": "ZC-E0104",
    "severity": "error",
    "blame": "user",
    "summary": "the request can't be understood",
    "explanation": "The request used a method the endpoint does not accept, or a query\nparameter that is repeated, unknown, malformed or out of range, or a\nrequest ID that is not 8 to 64 letters, digits and hyphens. For a\nservice it also covers container limits outside the runtime's bounds:\ncpu_millis 10 to 1,024,000 and memory_bytes 4 MiB to 2^40. The cause\nline names the part at fault. Nothing was changed.\n\nThe read-only API answers GET only. See docs/api.md for the parameters\nof each endpoint."
  },
  {
    "code": "ZC-E0105",
    "severity": "error",
    "blame": "user",
    "summary": "the service changed while it was being applied",
    "explanation": "Someone else applied or deleted the same service between the moment this\nrequest read it and the moment it tried to write. The store refused the\nwrite rather than overwrite their change. Nothing was changed.\n\nLook at the service as it is now (zcube get service), then apply again."
  },
  {
    "code": "ZC-E0106",
    "severity": "error",
    "blame": "user",
    "summary": "the server's configuration can't be used",
    "explanation": "zcube-server read its configuration file and flags and found a setting\nit cannot use: a file that is not valid ZON, an unknown setting, a store\nthat is not memory, sqlite:<path> or postgres:<settings>, or a listen\naddress that is not host:port. The cause line names the setting.\n\nNothing was started. Correct the setting and start the server again."
  },
  {
    "code": "ZC-E0107",
    "severity": "error",
    "blame": "environment",
    "summary": "can't listen on the server's address",
    "explanation": "zcube-server could not bind its listen address: another process already\nholds the port, the address is not one of this machine's, or the user\nmay not bind it (ports below 1024 need privileges).\n\nChoose another port with --listen, or stop the process that holds this\none. The cause line names the address and the system's reason."
  },
  {
    "code": "ZC-E0108",
    "severity": "error",
    "blame": "environment",
    "summary": "the server is at one of its limits",
    "explanation": "zcube-server refused a request because it is already serving as many\nconnections or waiting watches as it is configured to, or the request\nwas larger than it accepts. The cause line names the limit. Nothing was\nchanged.\n\nTry again shortly. A client that opens many watches should share one."
  },
  {
    "code": "ZC-E0109",
    "severity": "error",
    "blame": "user",
    "summary": "a file named on the command line can't be read",
    "explanation": "zcube could not read a file the command names: the service file of\nzcube apply, or the input file of zcube job run. It does not exist, is\nnot a regular file, or you may not read it, or zcube would need more\nmemory than it may use to read it. Nothing was sent to the server.\n\nThe cause line names the path and the system's reason. Check the path, or\nrun zcube from the directory that holds the file."
  },
  {
    "code": "ZC-E0110",
    "severity": "error",
    "blame": "user",
    "summary": "the service file isn't valid",
    "explanation": "The file is not a service written in ZON, or it names a field zcube does\nnot know. The context line gives file:line:column of the first problem and\neach cause line says what is wrong there. Nothing was sent to the server.\n\nA service has .name, .image, .replicas and .command; .env and .limits are\noptional:\n\n    .{\n        .name = \"hello\",\n        .image = \"b3:51aa9c03\",\n        .replicas = 3,\n        .command = .{ \"sh\", \"-c\", \"while true; do sleep 1; done\" },\n    }"
  },
  {
    "code": "ZC-E0111",
    "severity": "error",
    "blame": "user",
    "summary": "the command line can't be understood",
    "explanation": "zcube was given a command it does not have, a flag it does not know, a\nflag without its value, or too few or too many arguments. The cause line\nnames the part at fault. Nothing was sent to the server.\n\nzcube help lists the commands and flags."
  },
  {
    "code": "ZC-E0112",
    "severity": "error",
    "blame": "user",
    "summary": "the server address can't be used",
    "explanation": "The address given with --server, or in ZCUBE_SERVER, is not an IP address\n(or localhost) and a port, written HOST:PORT. Nothing was sent.\n\nWithout either, zcube talks to 127.0.0.1:7070, where zcube-server\nlistens by default."
  },
  {
    "code": "ZC-E0113",
    "severity": "error",
    "blame": "user",
    "summary": "apply needs an answer and there is no terminal",
    "explanation": "zcube apply shows what it would change and asks before it changes\nanything. Its input is not a terminal, so there is nobody to ask, and it\nwill not guess. Nothing was changed.\n\nRun it from a terminal, or give --yes to apply without being asked, as a\nscript does. The change is still shown first."
  },
  {
    "code": "ZC-E0114",
    "severity": "error",
    "blame": "user",
    "summary": "the apply was declined",
    "explanation": "zcube apply showed the change and the answer was not yes. Nothing was\nchanged on the server.\n\nApply again and answer y, or give --yes to skip the question."
  },
  {
    "code": "ZC-E0115",
    "severity": "error",
    "blame": "environment",
    "summary": "can't write the output",
    "explanation": "zcube could not write its result to standard output or standard error:\nthe descriptor is closed, the pipe has no reader, or the disk is full\n(for example when redirected to /dev/full). The command itself may have\nsucceeded: an apply is not undone by this failure.\n\nRun it again with output that can be written, or check with zcube get."
  },
  {
    "code": "ZC-E0116",
    "severity": "error",
    "blame": "environment",
    "summary": "can't use the state directory",
    "explanation": "zcube keeps the record of its last failure and the bundles it writes in\na state directory: $XDG_STATE_HOME/zcube, or $HOME/.local/state/zcube.\nNeither variable names an absolute path, or the directory can't be\ncreated or written. Bundles are only ever written there, never sent\nanywhere.\n\nName a directory you can write, for example\nexport XDG_STATE_HOME=$HOME/.local/state\n\nzcube local keeps its database, logs and containers in a directory of its\nown, $ZCUBE_LOCAL_DIR if that is set, else the local directory under the\nstate directory above. The same applies: it must be absolute, and zcube\nmust be able to create and write it. If ZCUBE_LOCAL_DIR is set, change or\nunset that one instead; XDG_STATE_HOME does not affect it."
  },
  {
    "code": "ZC-E0117",
    "severity": "error",
    "blame": "user",
    "summary": "there is no failure to bundle",
    "explanation": "zcube bundle --last collects the evidence for the last command of yours\nthat failed. None is recorded in the state directory: nothing has failed\nyet, or the record was deleted.\n\nName what to bundle instead: zcube bundle service <name>, or\nzcube bundle replica <id>."
  },
  {
    "code": "ZC-E0118",
    "severity": "error",
    "blame": "user",
    "summary": "no such diagnostic code",
    "explanation": "zcube explain was given a code that is not in the registry of Zigcube\n(ZC-) or of Zigbox (ZBX-). A code is a letter and four digits, with or\nwithout its prefix: E0201, ZC-E0201, ZBX-E0410.\n\nThe index of every code is at https://zigbox.github.io/zigcube/errors/"
  },
  {
    "code": "ZC-W0119",
    "severity": "warning",
    "blame": "user",
    "summary": "--no-redact keeps secrets in the bundle",
    "explanation": "Bundles replace environment values and anything that looks like a secret\nwith [redacted:<kind>]. --no-redact turns that off, so the bundle holds\nthem as they were. The command goes on.\n\nRead every file listed in MANIFEST.txt before you share the bundle, or\nleave --no-redact out. zcube never uploads a bundle."
  },
  {
    "code": "ZC-E0120",
    "severity": "error",
    "blame": "environment",
    "summary": "zcube ran out of memory",
    "explanation": "zcube asked for memory for an answer or a file and the system, or the\nlimit zcube keeps on itself, said no. Nothing is lost: a command that was\nsending a change may or may not have been applied, so check with\nzcube get service before you repeat it.\n\nAsk for less (one service by name instead of all of them), or free\nmemory on this machine."
  },
  {
    "code": "ZC-E0121",
    "severity": "error",
    "blame": "user",
    "summary": "the lease settings cannot fence an agent in time",
    "explanation": "An agent that loses contact with the server stops its containers a fixed\nmargin before its lease can run out, and the server places replacements\nonly after the lease has run out and a grace period has passed. The\nmargin must cover the time the agent needs to stop its containers, the\ndrift between the two clocks over one lease, and the time the kernel\nneeds to kill a process. These settings leave too little, so two copies\nof a replica could run at once.\n\nThe cause line names the numbers. A lease time to live that is too\nlong for the margin must be shortened. One that is too short, under\n8000 ms, leaves the agent no time to renew it before it fences, so it\nmust be lengthened; the cause line names the shortest. The default is\n10000 ms. An agent that is granted a lease time to live below 8000 ms\nby an older server stops its containers and reports this code."
  },
  {
    "code": "ZC-E0122",
    "severity": "error",
    "blame": "environment",
    "summary": "zcube local can't find or start the server or agent",
    "explanation": "zcube local up starts zcube-server and zcube-agent, and looks for them in\nthe directory that holds the zcube command itself. One of them is not\nthere, is not an executable file, or the system refused to start it, so\nnothing was left running.\n\nBuild all three with zig build and run zcube from zig-out/bin, or keep the\nthree files together when you install them."
  },
  {
    "code": "ZC-E0123",
    "severity": "error",
    "blame": "environment",
    "summary": "the local server or agent did not come up",
    "explanation": "zcube local up started zcube-server and zcube-agent, but the server did\nnot answer, or the node did not register, within the time zcube waits.\nBoth processes were stopped again. The cause line says which of the two\nsteps failed, and the server's own log, which names the real reason (a\nport in use, a database it could not open), is in the local directory.\n\nRead server.log and agent.log there. Your data is kept: zcube local up\ntries again with the same files."
  },
  {
    "code": "ZC-E0124",
    "severity": "error",
    "blame": "environment",
    "summary": "another zcube local command is running",
    "explanation": "zcube local up and zcube local down take turns: each holds a lock on the\nfile lock in the local directory while it starts or stops the server and\nthe agent, so two of them never fight over the same processes. Another one\nheld the lock for longer than this one was willing to wait.\n\nWait for the other command to finish and run this one again. The lock is\nreleased when its holder ends, however it ends, so it is never stale."
  },
  {
    "code": "ZC-E0125",
    "severity": "error",
    "blame": "user",
    "summary": "a service's health check is not valid",
    "explanation": "The service file's `health` block describes a check that cannot run as\nwritten. A health check is a command run inside each replica's container:\nit needs 1 to 64 words with a non-empty first word, an `interval_ms` above\nzero and at most an hour, a `timeout_ms` above zero and no longer than the\ninterval, a `start_period_ms` of at most an hour, and `failure_threshold`\nand `success_threshold` of at least 1, each reaching its verdict within a\nday (threshold times interval). The cause line names the field.\n\nNothing was applied. Correct the service file and apply it again. C3\nchecks are commands only; a TCP or HTTP check waits for a network path\ninto the container."
  },
  {
    "code": "ZC-E0126",
    "severity": "error",
    "blame": "user",
    "summary": "a service's rollout policy is not valid",
    "explanation": "The service file's `rollout` block cannot be followed. A rolling update\nmust be able to move: `max_surge` and `max_unavailable` may not both be 0,\nand neither may exceed the 128 replicas a service may have. The times must\nnest: `min_ready_ms` below `ready_timeout_ms`, and `ready_timeout_ms` no\nlonger than `progress_deadline_ms`, which is at most a day. `grace_ms` is\nat most a minute. The cause line names the field.\n\nNothing was applied. Correct the service file and apply it again; a\nservice with no `rollout` block uses the default policy, which is valid."
  },
  {
    "code": "ZC-E0127",
    "severity": "error",
    "blame": "user",
    "summary": "there is nothing to roll back to",
    "explanation": "A rollback asks for a generation of the service other than the one it\nruns now, and the service's history holds none: it was created by one\napply and never changed what its replicas run, or its history was deleted\nwith an earlier service of the same name.\n\nNothing was changed. To run something else, apply the service file you\nwant; `zcube history <service>` lists the generations there are."
  },
  {
    "code": "ZC-E0128",
    "severity": "error",
    "blame": "user",
    "summary": "the generation to roll back to is no longer in the history",
    "explanation": "A service keeps the 16 newest generations it was applied with; an apply\nthat adds a 17th deletes the oldest. The generation the rollback named is\nolder than that, or was never one of this service's (a service deleted\nand applied again starts at generation 1 with no history).\n\nNothing was changed. `zcube history <service>` lists the generations that\ncan be restored. To run an older one, apply its service file again."
  },
  {
    "code": "ZC-E0129",
    "severity": "error",
    "blame": "user",
    "summary": "the service has no rollout to pause or resume",
    "explanation": "Pause stops a rollout starting or retiring replicas; resume lets a paused\nrollout go on. This service has no rollout, its rollout is complete, or\n(for resume) its rollout failed: a failed rollout can be paused, which\nstops an automatic rollback it owes, and resumed once paused. Pausing a\npaused rollout, or resuming one that is running, is not this error: it\nsucceeds and changes nothing.\n\nNothing was changed. `zcube rollout status <service>` shows what is\nrunning."
  },
  {
    "code": "ZC-E0130",
    "severity": "error",
    "blame": "user",
    "summary": "a job is not valid",
    "explanation": "`zcube job run`, or a POST to /v1/jobs, named a job that cannot run as it\nstands. The cause line names the field and the limit it broke: a name that\nis not 1 to 48 bytes of lowercase letters, digits and hyphens (none at\neither end), or the name `watch`, which /v1/jobs/watch reserves, no\ncommand or too many words, a deadline of zero or above 24 hours, a grace\nperiod above 60 seconds, env above 8 KiB, an input above 64 KiB or with a\nNUL byte, a submit time more than an hour ahead,\nmore labels than a job may carry, a label or env key given twice, or a\n`limits` member outside its range (`cpu_millis` 10 to 1,024,000,\n`memory_bytes` 4 MiB to 2^40, `pids` 1 to 4,194,304).\n\nTwo fields are refused because they are not built yet, and the cause says\nso: retries above 0 (a job runs at most once), and placement. Accepting a\nfield and ignoring it would say something false about where the job runs.\n\nA relay must be the name of one of the relays in the server's `relays`\nsetting; an unknown name is refused, and a job may not set ZCUBE_RELAY in\nits own env, because the relay's supervisor sets it.\n\nFix the field it names and submit again."
  },
  {
    "code": "ZC-E0131",
    "severity": "error",
    "blame": "user",
    "summary": "a different job already has that name",
    "explanation": "A job named this exists, and what you submitted differs from it in its\nimage, source, command, env, limits, deadline, grace period, labels, retries\nor input. Submitting the same job again is safe and changes nothing: the\nsecond POST answers with the job that exists. A different job is refused so\nthat a retry can never replace the one that ran.\n\nUse another name, or wait until the old job has ended and been removed (an\nended job is kept for at least an hour), then submit again."
  },
  {
    "code": "ZC-E0132",
    "severity": "error",
    "blame": "user",
    "summary": "there are too many jobs",
    "explanation": "The cluster holds as many jobs as it accepts: either the jobs not yet ended\nhave reached their bound, or too many jobs were created in the last 73\nhours, the longest an ended job can still be kept. The cause line says which\nbound and its value. The job was not created.\n\nWait for jobs to end, or cancel the ones you no longer need\n(zcube job cancel), and submit again. Ended jobs are removed by age, after\nat least an hour; nothing here removes them sooner."
  },
  {
    "code": "ZC-E0133",
    "severity": "error",
    "blame": "user",
    "summary": "no job by that name",
    "explanation": "No job with this name is stored. Either it never existed, or it ended and\nwas removed: an ended job is kept for at least an hour and at most a day.\n\nzcube job list shows the jobs that exist. A client that watches endings must\nrecord each one it has handled; a job it has not seen end may be gone."
  },
  {
    "code": "ZC-E0134",
    "severity": "error",
    "blame": "user",
    "summary": "the time to submit this job has passed",
    "explanation": "Every job is submitted with a submit-by time, at most an hour ahead. This\nPOST arrived after it, so the job was not created. The deadline exists so\nthat a retry of a POST can always find the job the first one made: an ended\njob is kept for at least as long as a submit window.\n\nSubmit again with a new submit-by time. If the job was created by an\nearlier attempt, zcube job get NAME shows it; do not assume it did not run."
  },
  {
    "code": "ZC-E0201",
    "severity": "error",
    "blame": "external",
    "summary": "can't reach the store backend",
    "explanation": "The control-plane store (Postgres or SQLite) did not answer. The server\nand every controller read and write desired state through it, so nothing\ncan be reconciled while it is down. Workloads already running on nodes\nkeep running.\n\nCheck that the database is up and that the connection settings in the\nserver's configuration are right, then retry. The cause line names the\nbackend and what it reported."
  },
  {
    "code": "ZC-E0202",
    "severity": "error",
    "blame": "external",
    "summary": "the store backend failed an operation",
    "explanation": "The store backend was reachable but refused or failed a read or a write\n(a full disk, a lock timeout, a schema that does not match this version).\nThe operation did not take effect; the store never applies half of a\ntransaction.\n\nThe cause line carries the backend's own message. Fix the condition it\nnames and retry."
  },
  {
    "code": "ZC-E0203",
    "severity": "error",
    "blame": "user",
    "summary": "that revision was compacted away",
    "explanation": "The store keeps history only back to its compaction point. A read or a\nwatch asked for a revision older than that, so the events in between can\nno longer be replayed.\n\nA client that follows changes (a controller, an agent) recovers by\nlisting the current state and watching again from the revision the list\nreturns. A person asking for an old revision with --at-revision should\nask for a newer one."
  },
  {
    "code": "ZC-E0204",
    "severity": "error",
    "blame": "user",
    "summary": "that revision does not exist yet",
    "explanation": "A read or a watch named a revision higher than the store's current one.\nRevisions only count up, one per committed write; a future revision is\na mistake in the caller, usually a revision copied from another store.\n\nUse a revision returned by this store."
  },
  {
    "code": "ZC-E0205",
    "severity": "error",
    "blame": "environment",
    "summary": "the lease has expired or was revoked",
    "explanation": "A lease holds keys alive for as long as its owner keeps renewing it. This\none is gone: it ran out of time (the owner could not reach the store in\ntime) or someone revoked it. The keys attached to it were deleted.\n\nA node agent that sees this has lost its place in the cluster. It stops\nits workloads, grants a new lease and registers again."
  },
  {
    "code": "ZC-E0206",
    "severity": "error",
    "blame": "user",
    "summary": "the request exceeds a store limit",
    "explanation": "Keys, values, transactions and result pages have fixed upper bounds. The\nrequest went over one of them: a key or value that is too long, a\ntransaction with too many operations, or a lease with a time to live\noutside the allowed range.\n\nThe cause line names the limit and its value. Shorten or split the\nrequest."
  },
  {
    "code": "ZC-E0207",
    "severity": "error",
    "blame": "environment",
    "summary": "the store has no free capacity for this",
    "explanation": "The store is full in a dimension it bounds on purpose: all watch slots\nare in use, all lease slots are in use, the memory set aside for the\nrequest was not enough for the result, or a record would take more\nbytes than the store keeps in one value (the cause gives both sizes).\n\nClose watches that are no longer needed, or ask for smaller pages. For\nan oversized record, shorten its largest field. If the limit is too low\nfor the fleet, raise it in the server's configuration."
  },
  {
    "code": "ZC-E0208",
    "severity": "error",
    "blame": "environment",
    "summary": "the store database is busy",
    "explanation": "Another process or connection held a lock the store needed and did not\nlet go within the time zcube waits, or Postgres ended the operation\nbecause it conflicted with another (a deadlock or a serialisation\nfailure). The operation did not take effect.\n\nOnly the zcube server should use a store while it runs. Look for a\nsecond server, a backup job or a manual sqlite3 or psql session that\nholds a transaction open on the same store, stop it, and retry. On\nPostgres, a long-running transaction in pg_stat_activity is the usual\ncause."
  },
  {
    "code": "ZC-E0209",
    "severity": "error",
    "blame": "external",
    "summary": "the store database is damaged or not a store",
    "explanation": "What zcube opened as its store is not a usable zcube store: a SQLite file\nthat is corrupt, truncated or of another kind (or empty and not meant to\nbe initialised), or a Postgres schema that holds other tables, lacks\nzcube's own, or has lost one of them.\n\nRestore from a backup, or point the server at a different file or\nschema. To start with an empty store, move the SQLite file aside, or\nname a schema that does not exist yet, and let the server create it.\nNothing was changed."
  },
  {
    "code": "ZC-E0210",
    "severity": "error",
    "blame": "user",
    "summary": "the store database is from a newer zcube",
    "explanation": "The store was written by a newer version of zcube, whose schema this\nversion does not understand. It refuses to touch the store rather than\nrisk damaging it.\n\nRun the zcube version that created the file, or upgrade this one. The\ncause line names both schema versions. Nothing was changed."
  },
  {
    "code": "ZC-E0211",
    "severity": "error",
    "blame": "user",
    "summary": "the store backend refused the credentials",
    "explanation": "Postgres was reachable but would not let zcube in: the password or the\nrole in the connection settings is wrong, or the server's pg_hba.conf\nhas no rule that admits this role from this host. Nothing can be read\nor written until it does.\n\nCheck the user and password in the server's store settings against\nwhat Postgres has (psql with the same settings shows the same error),\nor ask the database administrator for a pg_hba.conf rule. The first\ncause line carries Postgres's own message."
  },
  {
    "code": "ZC-E0212",
    "severity": "error",
    "blame": "user",
    "summary": "the store database does not exist",
    "explanation": "Postgres is up and accepted the connection, but the database named in\nthe store settings does not exist on that server (or this role may not\nconnect to it). zcube creates its tables, never the database itself.\n\nCreate the database, or correct its name in the settings. The cause\nline names it. Nothing was changed."
  },
  {
    "code": "ZC-E0213",
    "severity": "error",
    "blame": "external",
    "summary": "the store connection dropped during an operation",
    "explanation": "The connection to Postgres ended while an operation was in progress: the\nserver restarted or was stopped, a backend was terminated, or the\nnetwork between them failed. zcube reconnects before the next\noperation, but cannot retry this one.\n\nIf the cause line says nothing was changed, the operation was rolled\nback. If it says the outcome is unknown, the connection dropped while\nthe commit was in flight and the write may or may not have been\napplied: read the keys again before repeating it."
  },
  {
    "code": "ZC-E0214",
    "severity": "error",
    "blame": "user",
    "summary": "the store has no chain hash for that revision",
    "explanation": "Every revision the store commits gets a chain hash, which a client\nuses to notice a store that went backwards or forked. A store written by\na zcube from before the chain existed cannot recompute the hashes of\nrevisions it had already compacted, so its chain starts at the revision\nit was upgraded at, and the store has no hash for any revision below\nthat.\n\nAsk for a revision at or above the start of the chain; the cause line\nnames it. Nothing was changed."
  },
  {
    "code": "ZC-E0215",
    "severity": "error",
    "blame": "external",
    "summary": "the store went backwards or forked",
    "explanation": "The server remembers the highest revision it has seen and the chain\nhash of that revision. The store now answers with a lower revision,\nor with a different hash for the revision the server remembers, so\nwrites the store acknowledged are gone or the history has\ndiverged. This is what a failover to a replica that was behind, a\nrestore from an old backup, or a store pointed at by mistake looks\nlike. Acting on it would hand out placements and fences that\ncontradict ones already given.\n\nThe server stops: controllers do not step and every store call\nfails with this code until an operator looks. It never recovers by\nitself. Look at the store (which database, which replica, which\nbackup). If the rolled-back or forked store is the one to keep, run\nzcube store accept-rollback --confirm, which makes the server\nremember the store as it is now. The old and new revision and hash are\nshown in the reply of that command; a decision record that keeps them\nis not written yet.\n\nAn agent raises it too: it remembers the highest revision and hash\nthe server's answers carried, and refuses an answer from behind them.\nAfter accept-rollback on the server, remove the file remembered in\nthe agent's state directory and restart the agent."
  },
  {
    "code": "ZC-E0216",
    "severity": "error",
    "blame": "external",
    "summary": "the remembered revision file is unusable",
    "explanation": "The server keeps the highest store revision and chain hash it has\nseen in a small file in its state directory, so that a restart after\na lossy failover still notices that the store went backwards\n(ZC-E0215). The file could not be read, is not what the server\nwrote, or could not be written. A file that does not parse stops the\nstart: the server does not guess. A save that fails while the server\nruns does not stop it, but the file then lags behind what the server\nknows, and a crash in that time forgets the difference; the failure\nis shown once in the log and in GET /v1/status.\n\nCheck the state directory (--state-dir) and its permissions. If the\nfile is damaged and the store is the one to trust, delete the file;\nthe server then remembers the store as it finds it.\n\nAn agent raises it too, about the file remembered in its own state\ndirectory, which holds the highest revision and hash the server's\nanswers carried and the server address they came from. A file the\nagent cannot read, or did not write, stops its start; one written\nby a newer zcube-agent says so. A save that fails while the agent\nruns does not stop it: it warns once, naming the file, and tries\nagain. If the file is damaged, delete it and restart the agent; it\nthen remembers the server as it finds it."
  },
  {
    "code": "ZC-E0301",
    "severity": "error",
    "blame": "external",
    "summary": "a stored record can't be read",
    "explanation": "A controller, the agent or the API read a value from the store that is\nnot a record of the kind its key says: not JSON, a field of the wrong\ntype, or a name that breaks the naming rules. The API validates what it\nwrites, so something else wrote this key, or the store was edited by hand.\n\nThe cause line names the key. Fix or delete that key (zcube get shows\nit); the controller skips nothing silently and tries again on its next\npass."
  },
  {
    "code": "ZC-E0302",
    "severity": "error",
    "blame": "environment",
    "summary": "there is more to reconcile than one pass holds",
    "explanation": "A controller pass reads every service and replica, and each kind has a\nfixed upper bound so that a pass fits its memory. The store holds more\nthan that, so the pass stopped before changing anything it could not\nsee whole.\n\nThe cause line names the bound. Delete services that are no longer\nneeded; if the fleet really is this large, the bound is a constant in\nsrc/constants.zig and the next release raises it."
  },
  {
    "code": "ZC-E0303",
    "severity": "error",
    "blame": "environment",
    "summary": "a stored record is from a newer release",
    "explanation": "A value in the store carries a format version this release does not know:\na newer zcube wrote it, and this one is older. The value is not\nmalformed, so nothing was changed and nothing was skipped; this release\njust cannot say what the newer fields mean, and acting on a half-read\nrecord could undo the newer release's work.\n\nThe cause line names the key and both versions. Run the release that\nwrote the record, or upgrade this one; if you downgraded on purpose,\nrestore the store from the backup taken before the upgrade."
  },
  {
    "code": "ZC-E0304",
    "severity": "error",
    "blame": "user",
    "summary": "a rollout failed: a new replica did not become ready",
    "explanation": "A rollout starts replicas of the new generation a few at a time and\nretires old ones only once new ones are ready. A new replica did not\nbecome ready within `ready_timeout_ms`: it exited, was held, or its\nhealth check kept failing. The new version is at fault, not the cluster.\n\nThe cause line names the replica and what it did. With `on_failure`\nrollback (the default) the service is rolled back to the generation it\nran before; with `pause` the rollout stops where it is. Fix the release,\nthen apply it again; `zcube why replica <id>` shows its last failure."
  },
  {
    "code": "ZC-E0305",
    "severity": "error",
    "blame": "environment",
    "summary": "a rollout stalled: a new replica cannot be placed",
    "explanation": "A rolling update starts each new replica before it retires an old one\n(`max_surge`), so for a while the service needs room for more replicas\nthan it has. No ready node had room for the next new replica, so the\nrollout cannot go on without breaking `max_unavailable`.\n\nThe cause line names the replica and what it needs. Add a node or free\ncapacity, or allow the rollout to retire first (`max_unavailable` above\n0); the rollout continues by itself once a replica can be placed. If it\nis still stalled when `progress_deadline_ms` passes, it fails with this\ncode, not ZC-E0306, and follows `on_failure` like any failed rollout."
  },
  {
    "code": "ZC-E0306",
    "severity": "error",
    "blame": "user",
    "summary": "a rollout passed its progress deadline",
    "explanation": "A rollout must finish within `progress_deadline_ms` of its start. This\none did not: new replicas became ready too slowly, or not at all, though\nnone failed outright. (A rollout stalled for room when its deadline\npassed fails with ZC-E0305 instead.)\n\nWith `on_failure` rollback (the default) the service is rolled back to\nthe generation it ran before; with `pause` the rollout stops where it is.\nIf the new version is right but slow to start, raise the deadline in the\nservice file and apply it again."
  },
  {
    "code": "ZC-W0304",
    "severity": "warning",
    "blame": "user",
    "summary": "a rollout paused itself after a failure",
    "explanation": "The service's rollout policy says `on_failure: pause`, and the rollout\nfailed (ZC-E0304, ZC-E0305 or ZC-E0306). It stopped where it was:\nreplicas of both generations keep running, and nothing is started or\nretired until you act.\n\n`zcube rollout status <service>` shows both generations. Resume with\n`zcube rollout resume <service>`, roll back with `zcube rollback\n<service>`, or apply a fixed release."
  },
  {
    "code": "ZC-W0305",
    "severity": "warning",
    "blame": "user",
    "summary": "a rollout was rolled back automatically",
    "explanation": "The rollout of a new generation failed (ZC-E0304, ZC-E0305 or\nZC-E0306) and the service's rollout policy is `on_failure: rollback`,\nthe default. The service was applied again with the spec of the\ngeneration it ran before, as a new generation, and that rollout\nreplaces the failed replicas.\n\nThe summary names the failing replica and the generation restored. Fix\nthe release and apply it again; a newer apply always wins over an\nautomatic rollback."
  },
  {
    "code": "ZC-E0307",
    "severity": "error",
    "blame": "external",
    "summary": "a job's stored records contradict each other",
    "explanation": "The records of one job (its desired state, its run, its status and what its\nnode reported) do not agree: a run with no job, a status that has ended and\ncarries no ending, an ending that does not match its state. The API writes\nthem together and validates what it writes, so something else wrote one of\nthe keys, or the store was edited by hand.\n\nThe cause line names the job and the keys. The job controller changes\nnothing for that job until it is fixed.\n\nNever fix it by deleting the job's run (/job-runs/NAME) or its status\n(/job-status/NAME) alone. A job that lost its run could be started a\nsecond time, and its ending lost; the controller refuses to create a run\nfor a job that had one, and changes nothing. Restore the missing or\ndamaged record, or, to remove the whole job, delete all of its keys in\none transaction: /jobs/NAME, /job-input/NAME, /job-runs/NAME,\n/job-status/NAME and /job-observed/NODE/NAME."
  },
  {
    "code": "ZC-W0307",
    "severity": "warning",
    "blame": "environment",
    "summary": "a report for an ended job was dropped",
    "explanation": "An agent reported on a run whose job had already ended. A job's ending is\nwritten once and never changes, so the report was not applied; it is\nrecorded in the job's decisions so that it can be seen.\n\nThis is normal after a node was cut off and came back: the control plane\nended the job as unreachable, and the agent then reported what it had\ndone. zcube why job NAME shows both."
  },
  {
    "code": "ZC-W0308",
    "severity": "warning",
    "blame": "user",
    "summary": "a job waits: no node can take it now",
    "explanation": "The scheduler placed nothing for this job yet. Either no node has the CPU,\nmemory or room it asks for, or every node already holds the most jobs it\nmay. The job stays pending and is looked at again whenever a node or an\nassignment changes.\n\nA job that is not started within its deadline ends as failed (deadline).\nLower its limits, add a node, or wait for a job to end. zcube why job NAME\nnames the shortfall."
  },
  {
    "code": "ZC-E0401",
    "severity": "error",
    "blame": "user",
    "summary": "a repair needs confirming",
    "explanation": "zcube repair allocations rewrites a node's allocation record, the\nscheduler's accounting of what is placed there, with the total rebuilt\nfrom the node's assignments. It changes authoritative state, so it runs\nonly when asked twice: the cause line says what it would write, and\nnothing was changed.\n\nLook at zcube check allocations first. If the rebuilt total is right,\nrun the same command again with --confirm."
  },
  {
    "code": "ZC-E0402",
    "severity": "error",
    "blame": "user",
    "summary": "the node has no open allocation finding",
    "explanation": "A node's allocation record is repaired only while the allocation auditor\nhas an open finding on it: the finding is the evidence the repair cites.\nThis node has none, so its accounting agreed with its assignments when\nlast audited, or the node is not known. Nothing was changed.\n\nRun zcube check allocations to see every node's accounting."
  },
  {
    "code": "ZC-E0403",
    "severity": "error",
    "blame": "user",
    "summary": "the node's accounting changed during the repair",
    "explanation": "The repair read a node's assignments and allocation record, and before\nit could write the rebuilt total the scheduler placed or released a\nreplica there, or the auditor changed its finding. It tried again a few\ntimes and the accounting kept moving, so nothing was written.\n\nRun the command again. zcube check allocations shows whether the node\nstill needs it."
  },
  {
    "code": "ZC-E0404",
    "severity": "error",
    "blame": "user",
    "summary": "a node's accounting disagrees with its assignments",
    "explanation": "zcube check allocations rebuilt each node's allocation from its\nassignments and found at least one node whose allocation record says\notherwise. The table on standard output shows both totals; the command\nexits 1 so that a script notices. Nothing was changed.\n\nA disagreement is a bug (ZC-B0003, which the allocation auditor records\non the node). While it stands the scheduler places nothing on that node.\nCollect a bundle of the node, then repair its accounting with zcube\nrepair allocations <node>, which says what it would write."
  },
  {
    "code": "ZC-E0501",
    "severity": "error",
    "blame": "environment",
    "summary": "the runtime does not know that container",
    "explanation": "The agent asked the runtime about a container by name and the runtime has\nno record of it. The agent starts every container itself and re-adopts the\nones it finds after a restart, so this means the runtime's state directory\nwas emptied or replaced while the agent was running.\n\nThe workload is treated as lost and the controller starts a replacement.\nCheck that nothing else is cleaning the agent's state directory."
  },
  {
    "code": "ZC-E0502",
    "severity": "error",
    "blame": "environment",
    "summary": "the runtime failed an operation",
    "explanation": "The runtime could not carry out a request that is not about one workload's\nimage or command: listing its containers, stopping one, reading its state\ndirectory, or running out of the slots it provisions at startup.\n\nThe cause line names the operation and what the host reported. A failure\nto start one workload is not this code: it is reported on that workload,\nwith the runtime's own diagnostic."
  },
  {
    "code": "ZC-E0503",
    "severity": "error",
    "blame": "environment",
    "summary": "the agent can't reach zcube-server",
    "explanation": "The agent asked zcube-server for its replicas or told it what it saw, and\nthe connection failed: the server is down, the address in the agent's\nconfiguration is wrong, or the network between them is broken.\n\nWorkloads keep running while the server is away: each runs under a\nsupervisor of its own. The agent retries with a growing pause and reports\nonce when the server is back. Check that the server is up and that\n--server names its address."
  },
  {
    "code": "ZC-E0504",
    "severity": "error",
    "blame": "external",
    "summary": "zcube-server refused the agent's request",
    "explanation": "zcube-server answered the agent with an error it does not expect, or with\na reply the agent cannot read. The cause line carries the server's own\ndiagnostic. The server and the agent are probably different versions,\nor something between them is answering in the server's place.\n\nUse the agent that came with the server. The agent retries; nothing it\nruns is stopped meanwhile."
  },
  {
    "code": "ZC-E0505",
    "severity": "error",
    "blame": "user",
    "summary": "the agent's configuration can't be used",
    "explanation": "A flag or a setting in the agent's ZON file is missing, unknown or out of\nrange, or the image fixtures file it names cannot be read. The cause\nline names the setting. The agent did not start and changed nothing.\n\nRun zcube-agent --help for the flags and the file's fields."
  },
  {
    "code": "ZC-E0506",
    "severity": "error",
    "blame": "environment",
    "summary": "the agent's state directory can't be used",
    "explanation": "The agent keeps one directory per container, holding the container's\nspec, the run record its supervisor writes and the lock that shows the\nsupervisor is alive. The directory could not be created or read, or\nanother agent is using it.\n\nCheck the path and its permissions, and that only one agent uses it. The\ncause line names the path and what the host reported."
  },
  {
    "code": "ZC-E0507",
    "severity": "error",
    "blame": "environment",
    "summary": "the agent can't start a container's supervisor",
    "explanation": "Each container runs under a supervisor, the agent's own executable started\nagain. The host refused to start it: no process slots, no memory, or the\nexecutable is gone. The container was not started.\n\nThe cause line says what the host reported. Free process slots or restart\nthe agent from its installed executable; the controller retries."
  },
  {
    "code": "ZC-E0508",
    "severity": "error",
    "blame": "user",
    "summary": "the container's command can't be run",
    "explanation": "The supervisor could not execute the replica's command: the program was\nnot found on the node, is not executable, or is not a program. Nothing\nof the workload ran.\n\nCheck the command in the service file. The replica is held, not retried:\na new one would fail the same way. Apply the corrected file to replace it."
  },
  {
    "code": "ZC-E0509",
    "severity": "error",
    "blame": "environment",
    "summary": "the container's supervisor is gone",
    "explanation": "The container's supervisor process ended without writing a run record,\nso nobody knows how the command ended: it was killed, or the host\nrestarted. The agent stops any process of the container that is left,\nand the controller starts a replacement.\n\nIf this repeats, look for something killing zcube-agent processes (an\nout-of-memory killer, a cleanup job) on the node."
  },
  {
    "code": "ZC-E0510",
    "severity": "error",
    "blame": "environment",
    "summary": "the agent's tenure on its node has ended",
    "explanation": "An agent writes what it observed only while it holds tenure on its node:\nwhile the node's registration is the one it made. This write named a\nregistration that has since ended or been replaced, because the lease\nran out or another registration took its place. Nothing was written.\n\nThe agent stops its containers, registers again and reports from the\nnew tenure. Nothing needs doing unless this repeats: then two agents\nmay be using one node name, or the agent is cut off for longer than\nthe lease time to live."
  },
  {
    "code": "ZC-E0511",
    "severity": "error",
    "blame": "user",
    "summary": "the image does not give the tree the service names",
    "explanation": "The node pulled the image from the reference it has for this tree, and\nthe files it unpacked to are not the tree the service's image digest\nnames. Nothing was started.\n\nEither the reference points at another image than the one the digest\nwas made from, or the digest was made for another platform (the node's\narchitecture decides which image of a multi-platform reference it gets).\nPull the reference again with Zigbox, take the tree digest it prints and\nput that in the service file."
  },
  {
    "code": "ZC-E0512",
    "severity": "error",
    "blame": "environment",
    "summary": "the node can't apply limits: no user systemd bus",
    "explanation": "The service sets a CPU, memory or process limit. Zigbox applies limits\nthrough a cgroup scope that the user's systemd creates, and the agent's\nuser has no systemd user bus (no login session, or lingering is off).\nThe container was not started: running it without its limits would\nnot be what the service asked for.\n\nEnable lingering for the agent's user (loginctl enable-linger) and make\nsure XDG_RUNTIME_DIR names its runtime directory, or remove the limits."
  },
  {
    "code": "ZC-E0513",
    "severity": "error",
    "blame": "environment",
    "summary": "this host can't run Zigbox containers",
    "explanation": "The agent was started with --runtime zigbox on a host that can't run\nrootless containers: Zigbox needs cgroup v2, user namespaces, uidmap\nand the other things its doctor checks. The agent did not start.\n\nRun zbx doctor as the agent's user; it names each missing piece and how\nto fix it. Use --runtime fake for a node that only runs test workloads."
  },
  {
    "code": "ZC-E0514",
    "severity": "error",
    "blame": "user",
    "summary": "the service does not fit Zigbox's limits",
    "explanation": "The replica's name, command or environment is longer than Zigbox keeps\nin a run record. The container was not started.\n\nThe cause line says which. Shorten it in the service file and apply the\nfile again; the replica is held, not retried."
  },
  {
    "code": "ZC-E0515",
    "severity": "error",
    "blame": "environment",
    "summary": "a swarm fetch outlived its kill, so the image was not pulled",
    "explanation": "A replica's image was being fetched from peers into this node's Zigbox\nstore, the fetch passed its deadline (or ended badly), and the supervisor\nkilled the fetch's whole process group with SIGKILL. A process of that\ngroup was still alive afterwards. It may still be writing the store, and\nZigbox's store takes one writer at a time, so the supervisor did not\nstart the registry pull: the replica was not started.\n\nA process that outlives SIGKILL is in uninterruptible sleep, waiting on\nthe kernel: usually a disk or a network mount that stopped answering.\nFind it (ps -eo pid,stat,wchan:32,args, state D) and the device it waits\non. The replica is started again on a later pass once it is gone."
  },
  {
    "code": "ZC-E0516",
    "severity": "error",
    "blame": "environment",
    "summary": "a replica's health check could not run",
    "explanation": "The agent runs a replica's health check as a command inside its\ncontainer. The command could not be started there at all: the runtime\nrefused it, and its code is the cause. This says nothing about whether\nthe replica is healthy, so it counts as neither a pass nor a failure.\n\nRead the runtime's code in the cause line: a container that has just\nstopped, or a runtime that does not support running a command in a\ncontainer, are the usual reasons. If the cause is a broken contract of\nthe runtime itself, report it with the diagnostic bundle."
  },
  {
    "code": "ZC-E0521",
    "severity": "error",
    "blame": "environment",
    "summary": "the agent could not tell how a run ended",
    "explanation": "A run's container is gone and nothing says how it ended: the agent lost its\nstate directory or the supervisor's exit record, or the host restarted, so\nthe process that was running it no longer exists and left no exit status.\n\nThe job ends as failed (unknown). It is never started again: a run is\nstarted at most once, and starting it to find out would break that. The\ncause line names the run and what was missing.\n\nFind out why: a host restart (uptime, the system log) or a state directory\nthat was cleared, moved or not mounted (the agent's --state-dir). Fix that\nfirst, or the next run can be lost the same way; then submit the job again\nunder a new name if it should run."
  },
  {
    "code": "ZC-E0522",
    "severity": "error",
    "blame": "environment",
    "summary": "a run's start record is missing or damaged",
    "explanation": "Before a run is started the agent writes a record of it in its state\ndirectory, so that after a crash it can tell a run it has started from one\nit has not. This record was missing, or could not be read.\n\nThe agent does not guess: it starts nothing it cannot prove it has not\nstarted. The run is reported as lost and its job ends as failed (unknown).\nCheck the state directory's disk and permissions."
  },
  {
    "code": "ZC-E0523",
    "severity": "error",
    "blame": "environment",
    "summary": "a run's input does not match its digest",
    "explanation": "A job that was submitted with an input stores the input once and names it\nin the run by its SHA-256 digest. The agent fetched the input after it\nclaimed the run and checked it against that digest. Either the server\nholds no input for the run, or what it holds does not hash to the digest.\n\nThe API wrote both the run and the input, so this is a damaged or edited\nstore, or a bug in Zigcube, never something the job's author did. The\nagent starts nothing it cannot verify: the run ends as failed\n(start_failed) and is not started again. A fetch that fails for any\nother reason, such as a network error, is not this: it is tried again.\n\nReport it with the diagnostic bundle, then submit the job again."
  },
  {
    "code": "ZC-W0501",
    "severity": "warning",
    "blame": "environment",
    "summary": "the agent fenced itself and registered again",
    "explanation": "The agent could not renew its lease in time, or the server said its\nlease or tenure had ended. It stopped every container, so that nothing\nruns on this node that the cluster may have placed elsewhere, then\ngranted a new lease and registered again with nothing running.\n\nThis happens when the agent was paused or cut off from the server for\nlonger than the lease time to live less the fencing margin."
  },
  {
    "code": "ZC-W0502",
    "severity": "warning",
    "blame": "user",
    "summary": "a replica's health check timed out",
    "explanation": "The health check command ran in the replica's container for longer than\nthe service's `timeout_ms` and was stopped. It counts as a failed check:\n`failure_threshold` failures in a row make the replica unhealthy.\n\nThe cause line names the replica and the timeout. Make the check\ncommand faster, or raise `timeout_ms` (at most `interval_ms`) in the\nservice file and apply it again."
  },
  {
    "code": "ZC-W0503",
    "severity": "warning",
    "blame": "user",
    "summary": "a job reached its deadline and was stopped",
    "explanation": "A job ran for as long as its deadline allows, counted from the moment it\nstarted on this node's clock. The agent asked the process to stop, waited\nfor the job's grace period, and then killed it. The job ends as failed\n(deadline).\n\nRaise the deadline, at most 24 hours, if the job needs the time; a job that\nshould be faster is a job to look at."
  },
  {
    "code": "ZC-W0504",
    "severity": "warning",
    "blame": "environment",
    "summary": "a pull record was not stored",
    "explanation": "A fetch or a pull on this node finished, but the record of what\nit moved (the bytes by source, which /v1/stats/pull shows) was\nlost. It could not be written to the container's directory, or\nthe agent read it and dropped it because it was not a pull\nrecord for this node, or zcube-server refused it; the cause line\nsays which. The image is not affected and the replica goes on;\nonly the statistics are missing.\n\nThe agent drops a record it cannot store so that one bad file\nnever blocks the ones after it. If the cause is a refusal, use\nthe agent that came with the server. If it is the state\ndirectory, check its disk space and permissions."
  },
  {
    "code": "ZC-E0601",
    "severity": "error",
    "blame": "external",
    "summary": "a tree could not be fetched from any peer or the registry",
    "explanation": "A node needed the chunk tree of an image and could not get it onto this\nnode: no peer sent it, and the registry did not serve it. The cause line\nnames the tree's digest and every source that was tried, in order.\n\nCheck that the registry is reachable from this node, and that the digest\nnames an image that was pushed. A digest that was never pushed is held by\nno source, so every fetch of it fails the same way."
  },
  {
    "code": "ZC-W0601",
    "severity": "warning",
    "blame": "external",
    "summary": "a peer sent a chunk that does not match its hash",
    "explanation": "A node that was asked for a chunk of an image sent bytes whose hash is not\nthe chunk's. The chunk was dropped and the node asked for no more from\nthat peer during this fetch; it came from another peer or the registry.\n\nThe image is not affected: nothing is stored or run before every chunk\nmatches. The peer's disk or store may be damaged, or it may be running a\ndifferent build; check that node."
  },
  {
    "code": "ZC-W0602",
    "severity": "warning",
    "blame": "external",
    "summary": "a peer's chunk list does not match its digest",
    "explanation": "A node that was asked for an image's chunk tree got a list from a peer\nwhose BLAKE3 digest is not the tree's digest. The list was ignored and the\nnode tried the next source: another peer, then the registry.\n\nThe image is not affected: a tree is used only when its digest matches.\nNo action is needed. If it repeats, check the peer node, whose store may\nbe damaged or running a different build."
  },
  {
    "code": "ZC-W0603",
    "severity": "warning",
    "blame": "environment",
    "summary": "the swarm fetch ended without the tree",
    "explanation": "The supervisor of a replica tried to get the image's chunk tree from peers\nfirst, and that fetch ended without it: it did not start, it exited with a\nfailure, or it was killed at its deadline. The cause line says which.\nThe registry pull follows, so the replica can still start; this line\nonly explains why the peers did not supply the tree.\n\nThe fetch's own diagnostic, in the same fetch.log, names the real\nreason when it had one (ZC-E0601 for a tree no peer could give, or the\ncode of this node's disk or memory failing). If the replica did not\nstart, the pull's own diagnostic follows it. If it repeats on every\nstart, check the peers and the network between them."
  },
  {
    "code": "ZC-E0701",
    "severity": "error",
    "blame": "external",
    "summary": "a relay's upstream refused a connection",
    "explanation": "A job's relay accepted a connection from the job and tried to connect to\nits upstream, the address the server's configuration names for that relay,\nand the connection was refused or reset, or the address could not be\nreached. The job's connection was closed. Other connections through the\nrelay are not affected.\n\nCheck that the upstream is running and that this node can reach it: the\nrelay connects from the node, not from inside the job. Correct the relay's\naddress in the server's `relays` setting if it is wrong; jobs submitted\nafterwards use the new address, and a job already running keeps the one it\nstarted with."
  },
  {
    "code": "ZC-E0702",
    "severity": "error",
    "blame": "environment",
    "summary": "a job's relay could not listen",
    "explanation": "The supervisor of a job could not set up the relay the job asked for, so the\njob does not run without the route it was promised. The cause line says\nwhich step failed (the socket, the bind, the listen, the relay's address).\n\nOn the fake runtime the job is not started and ends as a start failure. On\nthe real runtime the container has already started, so the supervisor kills\nit: it ends as killed by signal 9 and the cause is the line `ZC-E0702` in\nthe job's `relay.log`.\n\nIf the cause is a socket or file descriptor error, the host may be out of\ndescriptors: check `ulimit -n` and the node's load. If it names the relay's\naddress, correct the relay's address in the server's `relays` setting. Then\nsubmit the job again."
  },
  {
    "code": "ZC-E0703",
    "severity": "error",
    "blame": "environment",
    "summary": "this agent's build cannot serve a job's relay",
    "explanation": "An assignment names a relay and this node's agent cannot give the job one:\nits runtime has no way to hand a container a listener yet. The job ended as\na start failure instead of running without its relay.\n\nRun the job on nodes whose agent has relay support, or upgrade this agent to\nthe release that carries it. The agent and the server are upgraded\ntogether: the agent first, then the server."
  },
  {
    "code": "ZC-E0704",
    "severity": "error",
    "blame": "external",
    "summary": "a relay's upstream did not answer in time",
    "explanation": "A job's relay tried to connect to its upstream and nothing answered within\n10 seconds. The job's connection was closed. A black-holed route, a\nfirewall that drops packets or a host that is down all look like this.\n\nCheck the route from this node to the upstream named in the server's\n`relays` setting. The job may connect again; each attempt waits the same\n10 seconds and takes one of the job's 16 connection slots meanwhile."
  },
  {
    "code": "ZC-E0705",
    "severity": "error",
    "blame": "environment",
    "summary": "a relayed connection failed in the middle",
    "explanation": "A connection through a job's relay was open and then a read or a write on\nit failed: the peer reset it, or the host refused the call. Both ends were\nclosed. Bytes already copied were delivered; nothing is retried, because\nthe relay cannot know which request the bytes belonged to.\n\nA reset by the job or the upstream is ordinary and needs no action. If it\nrepeats on every connection, check the node's network and the upstream."
  },
  {
    "code": "ZC-W0701",
    "severity": "warning",
    "blame": "user",
    "summary": "a job's relay is at its connection limit",
    "explanation": "A job opened a seventeenth connection through its relay while sixteen were\nopen. The new connection was closed at once and counted; the open ones are\nnot affected. The limit is per job and fixed.\n\nThe job should reuse connections or close them when it is done with them.\nA connection that sits idle holds its slot for up to five minutes."
  },
  {
    "code": "ZC-W0702",
    "severity": "warning",
    "blame": "user",
    "summary": "a relayed connection reached its byte or idle bound",
    "explanation": "A connection through a job's relay was closed by the relay itself: it had\ncarried 1 GiB in one direction, or neither side had sent a byte for five\nminutes. The cause line says which. The job's other connections are not\naffected.\n\nOpen a new connection to go on. A job that needs a connection quiet for\nlonger than five minutes should send something now and then."
  },
  {
    "code": "ZC-E0801",
    "severity": "error",
    "blame": "external",
    "summary": "a peer's credential is not signed by this cluster",
    "explanation": "A node presented a credential that the cluster's certificate authority\ndid not sign: its key id is not this cluster's, or its signature does not\nverify. The connection was closed before anything was exchanged.\n\nThe control plane is the authority. A node gets its credential when its\nagent joins (POST /v1/agent/nodes/<node>/credential). A node that never\njoined, or joined a different cluster, is refused by every peer.\n\nCheck that the node's agent talks to this cluster's server, and that its\nca.pub in the agent state directory is the one this server serves. Deleting\nthe agent's peer.cred makes it join again."
  },
  {
    "code": "ZC-E0802",
    "severity": "error",
    "blame": "external",
    "summary": "a peer's credential is expired or not yet valid",
    "explanation": "A node presented a credential outside its validity window, judged on this\nmachine's wall clock with a skew allowance of 60 seconds. A credential lives\n24 hours and the agent renews it after half that.\n\nThe usual causes are a node whose clock is far off, or an agent that\ncould not reach the server for a day. Check the clock on both machines\n(timedatectl). The agent renews by itself, on start and at half the life,\nand retries every few seconds when the server refuses."
  },
  {
    "code": "ZC-E0803",
    "severity": "error",
    "blame": "external",
    "summary": "the peer is not the node that was asked for",
    "explanation": "A client connected to a node's peer address and the credential the server\npresented names a different node. The client closed the connection before it\nsent its own credential.\n\nThis happens when a node's address in /nodes/<node> is stale and another\nnode now answers there. It resolves itself when the agent re-registers;\ncheck zcube get nodes for the address."
  },
  {
    "code": "ZC-E0804",
    "severity": "error",
    "blame": "external",
    "summary": "a peer handshake failed",
    "explanation": "The handshake between two nodes ended before it finished: a message was\nmalformed, cut short or altered, a signature over the exchange did not\nverify, the peer spoke another protocol version, or a key was unusable. A\nserver that refuses a client closes the connection without a reply, so a\nrefusal and a network cut look alike from the client's side.\n\nNothing was transferred. If it repeats between two particular nodes, compare\ntheir clocks and their credentials (the agent's peer.cred), and look for the\nserver's own line naming the refusal. The handshake is interim; see\ndocs/peer.md."
  },
  {
    "code": "ZC-E0805",
    "severity": "error",
    "blame": "external",
    "summary": "a peer record was refused",
    "explanation": "A record on an established peer connection failed authentication: it was\naltered, repeated, dropped or reordered, or it was longer than allowed,\nor the connection reached its record limit. The connection was closed.\n\nWhatever was in flight is discarded and fetched again, from this peer or\nanother. Image data is checked by its hash regardless. A single\noccurrence on a flaky network is harmless; a pattern between two nodes\npoints at the path between them."
  },
  {
    "code": "ZC-E0806",
    "severity": "error",
    "blame": "user",
    "summary": "a peer key or trust file can't be used",
    "explanation": "The server's CA key (ca*.key in its state directory), the list of removed\nnodes (revoked), or an agent's node key (peer.key), credential (peer.cred)\nor trusted CA key (ca.pub) could not be read, created, written or parsed,\nor its file or directory has permissions that let other users read a secret\nor write a trust file. Key files must be owned by the process, mode 0600,\nand hold one line of 64 hex digits; the state directory must not be\nwritable by group or others. A revoked line must be a node name.\n\nThe secret is never printed. If the file is damaged and there is a backup,\nput it back. An agent's files are caches: it ignores a damaged peer.cred\nor ca.pub and joins again by itself; delete peer.key to get a new node key.\nA server whose CA key is missing although its store has run refuses to\nstart: put the key back, or start once with --new-ca to make a new CA on\npurpose (every agent then joins again by itself)."
  },
  {
    "code": "ZC-E0807",
    "severity": "error",
    "blame": "user",
    "summary": "a node was refused a credential: it was removed",
    "explanation": "The server will not issue or renew a peer credential for this node,\nbecause its name is on the server's list of removed nodes (the revoked\nfile in its state directory). The node's current credential stays valid\nuntil it expires, within a day, and then its peers refuse it.\n\nIf the node should be in the cluster, remove its name from the revoked\nfile and restart zcube-server; the agent asks again by itself. The API is\nunauthenticated, so this binds an honest node only: until the API has auth,\nanyone who can reach it can register a name and ask for a credential."
  },
  {
    "code": "ZC-E0808",
    "severity": "error",
    "blame": "external",
    "summary": "a peer's handshake was refused: its address is over a limit",
    "explanation": "An agent's peer server limits what one source address may ask of it,\nbecause a handshake costs the server public-key work. A handshake is\nrefused, and the connection closed without a byte, when the address\nalready has peer_handshakes_pending_per_source_max handshakes that\nhave not finished, when it has started peer_handshakes_per_source_max\nhandshakes in peer_handshake_window_ms, or when the server already\ntracks peer_sources_max addresses in the window. An IPv6 address\ncounts by its /64, one host's whole range.\n\nThe cause names the refused address (an IPv6 one by its /64). The\ntext is shown once per peer_refusal_log_ms, not once per connection.\nAn honest fetch opens a handful of connections and keeps\nthem. If one node is refused over and over, something there retries\nin a loop: look at its agent's output. A refused node tries again by\nitself, and a fetch falls back to the registry meanwhile. A flood\nfrom many addresses can fill the table and turn honest nodes away\nfor up to one window; no action is needed unless it repeats."
  },
  {
    "code": "ZC-E0809",
    "severity": "error",
    "blame": "external",
    "summary": "a certificate is malformed or outside the bounds",
    "explanation": "A certificate was refused before its signature was looked at. Zigcube reads\nX.509 v3 strictly: DER only, Ed25519 only, a lifetime within the bound, at\nmost x509_cert_bytes_max bytes. A certificate of this cluster also has one\ncommonName, the extensions of its kind in a fixed order and a SPIFFE ID of\nthe form spiffe://<cluster>/service/<name> (or one DNS name for a server).\nA server certificate under a pinned anchor of another CA may carry any\nnames, key identifiers and extension order, but no unknown critical\nextension, no extension twice, and one DNS name or SPIFFE ID (docs/mtls.md).\n\nThe cause names the field and the rule it broke. A certificate that the\ncluster CA issued does not break any; if one does, it did not come from\nzcube (another CA, a hand-made file) or it was damaged on the way.\n\nAsk for a new certificate from the cluster CA, or from the anchor's CA with\nthe profile docs/mtls.md describes."
  },
  {
    "code": "ZC-E0810",
    "severity": "error",
    "blame": "external",
    "summary": "a certificate is not signed by the pinned anchor",
    "explanation": "The certificate's issuer is not this cluster's CA, or its signature does\nnot verify under the pinned anchor key.\n\nOnly certificates signed directly by the one pinned key are accepted: no\nchain, no intermediate. The check comes before the validity window, so a\nforged certificate is never reported as expired.\n\nCheck that both sides were given the same cluster CA, and that the\ncertificate was issued after the last --new-ca. A certificate issued by an\nearlier CA must be replaced."
  },
  {
    "code": "ZC-E0811",
    "severity": "error",
    "blame": "external",
    "summary": "a certificate is expired or not yet valid",
    "explanation": "The certificate is signed by the pinned anchor but the current time is\noutside its validity window, allowing peer_clock_skew_ms of clock difference\non each side. The signature was checked first, so the certificate is\ngenuine. The cause shows notBefore, notAfter and this machine's time.\n\nCheck the clocks on both machines. A workload certificate lives for the\nservice's deadline, at most x509_leaf_ttl_ms_max: ask for a new one."
  },
  {
    "code": "ZC-E0812",
    "severity": "error",
    "blame": "external",
    "summary": "a certificate names another server than the one asked for",
    "explanation": "The server's certificate verified against the pinned anchor, but the name\nin its subjectAltName is not the name the connection was made to. Names are\ncompared exactly: no wildcard, no case folding. The cause shows both names.\n\nConnect to the name the certificate is for, or issue the server a\ncertificate for the name in the configuration."
  },
  {
    "code": "ZC-E0813",
    "severity": "error",
    "blame": "external",
    "summary": "a TLS handshake was refused",
    "explanation": "The peer's handshake message was malformed, came in the wrong order, held\na signature or Finished that does not verify, or the peer sent a fatal\nalert. Nothing was accepted: the connection is closed and no application\ndata was sent. The cause names the message and the rule, or the alert the\npeer sent.\n\nA signature or Finished that does not verify means the peer does not hold\nthe key of the certificate it showed, or the two sides saw different\nhandshakes. Check that the peer is a zcube server and that nothing between\nthe two rewrites the connection."
  },
  {
    "code": "ZC-E0814",
    "severity": "error",
    "blame": "external",
    "summary": "the TLS client certificate was not asked for, or was refused",
    "explanation": "The client was told to present a certificate and the server did not ask\nfor one, or the server refused the one presented (the alert names why:\nbad_certificate, certificate_expired, unknown_ca, certificate_required).\nA client that sends an empty Certificate (it has no certificate, or the\nrequest does not list Ed25519) and is refused by the server is this too,\nand so is a client that must authenticate facing a request without\nEd25519. The connection is closed; a refusal arrives after the client's\nown handshake is done, so data written before the alert was read was\nnot accepted.\n\nA server that never asks cannot learn which workload is calling, so a\nconnection that must prove identity stops. Check that the server is\nconfigured to require client certificates and trusts the cluster CA;\na refused certificate is expired, issued by another CA, or for a\ndifferent workload than the server allows. A signer that fails is a\ndifferent error (ZC-E0820)."
  },
  {
    "code": "ZC-E0815",
    "severity": "error",
    "blame": "external",
    "summary": "a TLS record failed its checks",
    "explanation": "A record was too long, too short, did not authenticate, or the connection\nreached the end of what its keys may protect. The connection is closed and\nthe keys are wiped.\n\nOn a healthy network this does not happen: it means bytes were changed in\ntransit, the peer is not speaking TLS 1.3, or a peer sent more than 2^24\nrecords without updating its keys, or asked this side to update its own keys\nmore often than tls_key_updates_per_connection_max allows (each request is\nanswered with an update). Reconnect; if it repeats, check the path\nbetween the two machines."
  },
  {
    "code": "ZC-E0816",
    "severity": "error",
    "blame": "external",
    "summary": "a TLS connection ended or stalled without close_notify",
    "explanation": "The peer's side of the connection ended before it sent close_notify, so the\ndata received may be cut short. Mid-handshake this means the peer hung up\nbefore the handshake finished.\n\nThe connection also ends this way when the peer stays connected and goes\nquiet: a handshake, or the answer to a KeyUpdate, did not finish in time\nbecause the peer stopped reading or answering. A black hole, an overloaded\nserver or a middlebox that drops packets looks like this.\n\nTreat what arrived as incomplete and retry the request. A peer that\ncrashes, or a network that resets the connection, ends this way; for a\nstall, check that the server is reachable and keeping up.\n\nA call on a connection that an earlier failure already ended raises it too,\nwith the cause \"the TLS connection already ended\"; the earlier call carried\nthe reason, and the fix is a new connection."
  },
  {
    "code": "ZC-E0817",
    "severity": "error",
    "blame": "user",
    "summary": "an identity could not be issued",
    "explanation": "A workload or server certificate was not made because its request breaks a\nbound: more labels than x509_labels_max, a label key or value over its limit\nor with a character that is not allowed, label keys not sorted and unique,\nlabels together over x509_labels_bytes_max, a cluster or service name that\ndoes not make a SPIFFE ID spiffe://<cluster>/service/<name>, a DNS name that\nis not lowercase, has a wildcard or an all-digit label, or a lifetime that\nis empty or over x509_leaf_ttl_ms_max (x509_ca_ttl_ms_max for a CA), or a\nsubject key that is not a valid Ed25519 public key (off the curve, or in a\nsmall subgroup), which no honest holder has.\n\nThe cause names the rule. Correct the request and issue again; nothing was\nwritten."
  },
  {
    "code": "ZC-E0818",
    "severity": "error",
    "blame": "external",
    "summary": "a TLS peer needs something zcube does not offer",
    "explanation": "zcube speaks TLS 1.3 only, with x25519, TLS_AES_128_GCM_SHA256 and Ed25519\nsignatures, and offers no resumption and no retry. The peer answered with\nan older protocol version, another suite, group or signature scheme, or a\nHelloRetryRequest. The cause names which.\n\nPeers of a zcube cluster are zcube servers. If this is not one, connect to\nthe right address; there is no setting that widens what zcube offers."
  },
  {
    "code": "ZC-E0819",
    "severity": "error",
    "blame": "external",
    "summary": "a certificate is of another kind than this use needs",
    "explanation": "The certificate is genuine and well formed, but it is not for this use: a\nworkload's client certificate presented as a server's, a CA certificate\npresented as a leaf, or, under a foreign anchor, a certificate whose\nextended key usage lacks serverAuth or whose basic constraints say CA.\n\nThe cause names the kind found and the kind needed. Give the peer a\ncertificate issued for its role: a server certificate for a server."
  },
  {
    "code": "ZC-E0820",
    "severity": "error",
    "blame": "environment",
    "summary": "the key behind the client certificate did not sign",
    "explanation": "The server asked for a client certificate and the client has one, but the\nsigner that holds its private key returned no signature, so the proof of\npossession (CertificateVerify) could not be made. The connection is\nclosed with an internal_error alert; nothing was accepted.\n\nThe key never enters the TLS client: it sits behind a signer, in the same\nprocess or in another. This is that signer failing, not the server or the\ncertificate. Check that the process or device holding the key is running\nand reachable, then reconnect."
  },
  {
    "code": "ZC-E0821",
    "severity": "error",
    "blame": "environment",
    "summary": "the operating system's secure random source failed",
    "explanation": "A key, a nonce or a seed was not made because the kernel's secure random\nsource (getrandom) returned an error. Nothing weaker is used instead, and\nnothing is retried.\n\nCheck that getrandom works where this runs: the kernel, the seccomp profile\nand the container sandbox must allow it. Then run the command again."
  },
  {
    "code": "ZC-B0001",
    "severity": "bug",
    "blame": "internal",
    "summary": "zcube hit an internal error",
    "explanation": "An invariant that zcube relies on did not hold. This is a bug in zcube,\nnot something you did.\n\nA diagnostic bundle is saved for every bug. Review its manifest, then\nattach it to a report at https://github.com/Zigbox/zigcube/issues/new."
  },
  {
    "code": "ZC-B0002",
    "severity": "bug",
    "blame": "internal",
    "summary": "zcube failed in a way it should not",
    "explanation": "A step of zcube stopped with an error that its own code is supposed to\nhandle before it reaches you. This is a bug in zcube, not something you\ndid, and the command may or may not have taken effect: check with\nzcube get.\n\nA diagnostic bundle is saved for every bug. Review its manifest, then\nattach it to a report at https://github.com/Zigbox/zigcube/issues/new."
  },
  {
    "code": "ZC-B0003",
    "severity": "bug",
    "blame": "internal",
    "summary": "allocation accounting disagrees with assignments",
    "explanation": "The allocation auditor rebuilt a node's allocation from its assignments\nand found a total that differs from the node's allocation record. Every\ntransaction that places or releases a replica updates that record, so a\ndifference can only come from a defect in zcube, never from the\nenvironment. The auditor records a finding and never repairs it: while\nthe finding is open the scheduler places nothing on the node, but it\nstill releases.\n\nRun zcube check allocations to see both totals. If the rebuilt one is\nright, zcube repair allocations <node> --confirm writes it. Please\nreport it at https://github.com/Zigbox/zigcube/issues/new with the\noutput of zcube why node <node>."
  },
  {
    "code": "ZC-B0004",
    "severity": "bug",
    "blame": "internal",
    "summary": "zcube could not map how a job ended",
    "explanation": "The job controller read an end of a run (an exit, a stop cause and what the\nagent reported) that none of its rules covers. The job is left as it was;\nnothing was ended or started. This is a bug in zcube, not something you\ndid.\n\nA diagnostic bundle is saved for every bug. Review its manifest, then\nattach it to a report at https://github.com/Zigbox/zigcube/issues/new."
  },
  {
    "code": "ZC-B0005",
    "severity": "bug",
    "blame": "internal",
    "summary": "a job's run record is larger than a run may be",
    "explanation": "The record of a job's run, once encoded, is larger than the bound on one\nrun (16 KiB). The API checks a job's words against their bounds before it\naccepts the job, so a job that reaches this point got past a check it\nshould have failed. This is a bug in zcube, not something you did, and\nnot a memory limit: raising limits changes nothing. The job is not started.\n\nA diagnostic bundle is saved for every bug. Review its manifest, then\nattach it to a report at https://github.com/Zigbox/zigcube/issues/new."
  }
];
