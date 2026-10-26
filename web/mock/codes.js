// Generated from src/diag/codes.zig by web/mock/gen-codes.mjs. Do not edit by hand.
export const ZC_CODES = [
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
