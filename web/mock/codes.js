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
    "explanation": "The request used a method the endpoint does not accept, or a query\nparameter that is repeated, unknown, malformed or out of range, or a\nrequest ID that is not 8 to 64 letters, digits and hyphens. The cause\nline names the part at fault. Nothing was changed.\n\nThe read-only API answers GET only. See docs/api.md for the parameters\nof each endpoint."
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
    "explanation": "The store is full in a dimension it bounds on purpose: all watch slots\nare in use, all lease slots are in use, or the memory set aside for the\nrequest was not enough for the result.\n\nClose watches that are no longer needed, or ask for smaller pages. If the\nlimit is too low for the fleet, raise it in the server's configuration."
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
    "code": "ZC-B0001",
    "severity": "bug",
    "blame": "internal",
    "summary": "zcube hit an internal error",
    "explanation": "An invariant that zcube relies on did not hold. This is a bug in zcube,\nnot something you did.\n\nA diagnostic bundle is saved for every bug. Review its manifest, then\nattach it to a report at https://github.com/Zigbox/zigcube/issues/new."
  }
];
