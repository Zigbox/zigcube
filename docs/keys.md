# Keys and values

The key layout of HANDOFF.md, with value shapes. Keys are `/`-separated absolute paths of
printable ASCII, at most 512 bytes (`src/store.zig`, `key_problem`). Values are JSON objects,
at most 256 KiB, because the API, the agents and `zcube why` all speak JSON and diagnostics are
JSON (DIAGNOSTICS.md). Service files are ZON; `zcube apply` converts them to the JSON below on
the client. Every value carries a version, `"v"`, so a field can be added later without guessing which
writer produced a record (below, "Versions"). Status: C0's layout was **approved 2026-10-26**
and is implemented; C1's additions (**approved 2026-10-27**, `authority.md`) are marked with the
slice that first writes them. Slice 2 only defined them (`src/records.zig`, `src/writers.zig`,
`src/compare_sets.zig`): until the slice named, no controller or agent writes them.

## Who writes what

One writer role per prefix (`authority.md` section 2, invariant I4). A transaction is made by
one role, and `writers.txn` (`src/writers.zig`) asserts at every call site that each of its puts
and deletes is that role's; a refusal is a defect, never an error.

| Prefix | Sole writer | First written |
| --- | --- | --- |
| `/services/<name>` | API | C0 |
| `/replicas/<service>/<id>` | replica controller | C0 |
| `/replica-numbers/<service>` | replica controller | C1 slice 3 |
| `/assigned/<node>/<id>` | scheduler | C1 slice 3 |
| `/nodes/<node>` | that node's agent | C0 |
| `/node-store/<node>` | that node's agent | C2 slice 5 |
| `/pulls/<node>/<tree>` | that node's agent (retention may delete) | C2 slice 7 |
| `/allocations/<node>` | scheduler | C1 slice 3 |
| `/audit/allocations/<node>` | allocation auditor | C1 slice 4 |
| `/node-status/<node>` | node controller | C1 slice 3 |
| `/observed/<node>/<id>` | that node's agent (the node controller may delete) | C0 |
| `/jobs/<name>`, `/job-input/<name>`, `/job-admission` | API | B1 slice 1 |
| `/job-runs/<name>`, `/job-status/<name>`, `/job-endings` | job controller | B1 slice 1 |
| `/job-observed/<node>/<name>` | that node's agent (retention may delete) | B1 slice 1 |
| `/decisions/…`, `/decisions-by-subject/…` | every role, in the transaction of the action | C0 |
| `/decision-summaries/…` | every role, in the transaction of the decision it counts | C1 slice 4 |

The cluster CA (`ca.key`, docs/peer.md) is not a writer: it signs credentials and writes no key.
Its files, the server's `ca.key` and `revoked` and the agent's `peer.key`, `peer.cred` and
`ca.pub`, live in the state directories, not in the store.

An agent writes only `/nodes/<its node>`, `/node-store/<its node>`, `/pulls/<its node>/…`, `/observed/<its node>/…` and `/job-observed/<its node>/…`.
The `zcube-agent fetch` process reads `/node-store/<node>` (`peer`, `filter`) to find peers, and
writes nothing.
One departure from `authority.md`, recorded in `docs/DECISIONS.md`: a seventh role, `retention`, deletes expired
decisions (and, from C2 slice 7, expired `/pulls/` records, delete only) and so may touch only those prefixes. `/services/<name>` is the API's alone:
the replica counter lives in `/replica-numbers/<service>` from slice 3, and `writers.zig`
refuses a put or delete of a service by any role but the API. `Service` v2 never starts a
`next_replica`: it carries a C0 record's value forward only until the counter exists (below). The replica controller reads a counter
only with a `get` when it is about to create replicas for that service, never by listing, so the
number of counters bounds nothing.
B1 adds an eighth role, `job_controller` (below, "Jobs"). `retention` also deletes, never writes, the
records of an ended job: `/jobs/`, `/job-input/`, `/job-runs/`, `/job-status/` and
`/job-observed/`, and may delete the five of one job in one transaction (one job, at most one node). It never deletes
`/job-admission`, `/job-endings` or an assignment.

## Versions

Every value has `"v"`. A reader accepts every version up to the one its release writes and
ignores members it does not know. `Service` and `Replica` write `"v": 3` (C2 slice 2 added
`source`); `Observed` writes `"v": 2` (it gained members in C1); `Assigned` writes `"v": 2` for a run (B1: it gained `job`) and `"v": 1` for a replica; `Decision` writes `"v": 3` (C2 slice 5 added `locality_bytes` and `node_store_revision`); `Pull` writes `"v": 1` (C2 slice 7); every other record
writes `"v": 1`. Records C0 and C1 wrote still read: the fixtures in `src/testdata/c0_store.txt`
and `c1_store.txt` were captured from real stores. A value with a **newer**
version than the reader knows is refused with one line naming the key and both versions,
`ZC-E0303`, never as a malformed record.

Names: a service name is a hostname label (lowercase letters, digits, `-`), at most 48 bytes,
so that a replica id fits Zigbox's 63-byte container-name rule. A node name follows the same
rule at 63 bytes.

## `/services/<name>`: desired service

```json
{ "v": 3, "name": "hello", "image": "b3:51aa9c03", "replicas": 3,
  "source": "registry.example/hello@sha256:<64 hex digits>",
  "command": ["sh", "-c", "while true; do sleep 1; done"],
  "env": [["KEY", "value"]], "limits": {"cpu_millis": 500, "memory_bytes": 134217728},
  "generation": 4, "next_replica": 17,
  "applied_by": "alex@laptop", "request_id": "r-0001a4f" }
```

Written by the API on `apply`. `generation` increases on every change of what a replica runs,
so a decision can say which version it acted on: the image, `source`, the command, `env` and
`limits`.
**A change of `replicas` alone does not bump it** (owner, 2026-10-26): scaling from 3 to 5 must
not replace the three that run. The replica controller replaces replicas whose `generation` is
behind, and only a change of the replica's own inputs puts one behind. It also replaces a replica
whose image, `source`, command, `env` or `limits` differ from the service's whatever its
`generation` says: `generation` starts again at 1 when a service is deleted and applied again, so a
replica of the old service can be ahead of the new one or equal to it. `next_replica` is the
counter that makes replica ids unique forever (below). From slice 3 it lives in
`/replica-numbers/<service>` (`{"next": N}`), which only the replica controller writes, in the
same transaction that creates the replica. It is **never deleted**: the key outlives the service
and its replicas (one small key per service name ever applied), so a re-apply continues the
numbering. A legacy `next_replica` on the service seeds it, and so does one past the highest
live replica number, whichever is larger, only when the key is absent. The seed is written on
the first pass that sees a service carrying `next_replica` without a counter, whether or not
it needs a replica, and a pass that stops the replicas of a deleted service with no counter
writes one past their highest number, so a C0 service deleted and applied again never reuses
an id. **What `"v": 2` holds:** no `next_replica` for a service created from slice 3; for a
service that was a C0 record, `apply` carries its `next_replica` forward while
`/replica-numbers/<service>` is absent and drops it once the counter exists. Readers ignore it
when the counter exists.

`applied_by` (the authenticated actor) and `request_id` (the API request that wrote this
version, the same id as in `--verbose` output and bundles) say who changed the service last
and let `zcube why` end its chain at a person and a request. A later `provenance` (git commit, file
digest) is reserved and not written yet.

`source` (C2 slice 2) is the OCI reference `image` is pulled from, when the node does not have the
tree: empty (and omitted by older records, which read as empty) means the tree must already be on
the node. `apply` accepts it empty, or at most 1024 bytes with no whitespace or control character,
ending in `@sha256:` and 64 lowercase hex digits (a digest pin: a tag can move). A change of
`source` bumps `generation`, so that fixing a bad reference reaches a replica held for it. It is
not a secret. The reference is the same name Zigbox's `pull` takes; the supervisor parses it.

**`env` values are secrets.** They are stored here, but the API never sends them to a
read-only token: it sends the names only (`"env": [["KEY", null]]` in the API's JSON, a null
value). A token that may write sees the values. Nothing outside the API, the replica copy below
and the agent reads them, and bundles redact them (DIAGNOSTICS.md).

## `/replicas/<service>/<id>`: desired replica

`<id>` is `<service>-<n>` with `n` from `/replica-numbers/<service>` (C0: the service's
`next_replica`), never reused: a replacement for
`hello-3` is `hello-9`, so an old container and its observed record can never be mistaken for
the new one. The id is also the container name and the `zcube.replica` label.

```json
{ "v": 3, "id": "hello-9", "service": "hello", "generation": 4,
  "image": "b3:51aa9c03", "source": "", "command": ["sh", "-c", "..."], "env": [], "limits": {} }
```

Version 2 (C1 slice 3) has no `node` and no `requests`; a version 1 record still reads, with
both ignored. Version 3 (C2 slice 2) adds `source`, copied from the service (empty when
absent). The agent's endpoint (`GET /v1/agent/nodes/<node>/replicas`) serves these records
for the replicas in `/assigned/<node>/` only; an assignment whose replica is gone is not served.

The replica copies what it needs from the service at creation, so editing the service does not
change a running replica; the controller replaces replicas whose `generation` is behind.
**From C1 slice 3 the replica carries no placement:** `/assigned/<node>/<id>` (below) is where
it runs, and `requests` is on the assignment (C0 wrote `node` and `requests` here). A replica
with no assignment is unscheduled. `requests`, and how a node's used capacity is counted, are
described with `/assigned` and `/allocations` below.

**A replica whose start failed through the user's fault is held, not replaced** (owner,
2026-10-26). When `/observed/<node>/<replica>` says `start_failed` with a diagnostic whose blame
is `user` (a digest that is not in the store, `ZBX-E0410`), the replica controller leaves the
replica where it is and writes a `hold_failed_replica` decision on the *service* (below). It does
not retry and does not create a replacement: a new replica would fail the same way, and replacing
it for ever would bury the cause in churn. A change of the service (a new `generation`) is what
replaces a held replica. Other failures (`environment`, `external`, an exit, `lost`) are replaced.

**Deleting the key
means "stop it"**: the agent stops any container labelled with a replica id it no longer finds,
and then removes the observed record.

## `/nodes/<node>`: node registration, attached to the node's lease

```json
{ "v": 1, "name": "node1", "agent_version": "0.0.0", "address": "10.0.0.5:7070",
  "capacity": {"cpu_millis": 4000, "memory_bytes": 8589934592}, "labels": [],
  "trust_policy": "/etc/zcube/trust.zon" }
```

`trust_policy` (B5 slice 2, optional, empty when absent) is the path of the policy the agent judges
every run against before it starts it (`--trust-policy`, an absolute path); empty means the
node registered no policy, or one that asks for no signature and no provenance: it checks nothing.
It is for people (`zcube why node`); no one acts on it. Like every member here it is the
registration's: an agent restarted under a live lease does not register again (docs/agent.md,
"Known limits"), so a node restarted without its policy can still show the old path while it
checks nothing.

Written by the agent with `lease` set to the lease it keeps alive. When the lease ends the key
is deleted by the store, and that delete event is how lost nodes are detected (C1). The key's
`mod_revision` at registration is the node's **tenure revision** (`authority.md` section 3). Capacity is
declared by the agent's configuration (see the open questions in `docs/contracts-review.md`).

## `/node-store/<node>`: what the node holds of the image trees (C2 slice 5)

```json
{ "v": 1, "node": "node1",
  "trees": [{"tree": "b3:51aa9c03", "bytes": 52428800, "chunks": 800, "sample": "<hex>"}],
  "filter": "<hex Bloom filter of every chunk held>", "filter_chunks": 800, "omitted": 0,
  "peer": "10.0.0.7:7700" }
```

`peer` is the `host:port` of the node's peer server (`--peer-listen`); empty when it serves
none. A fetch reads it instead of guessing from `/nodes/<node>`, whose port is the agent's API.

Written by the agent, bound to the same lease as `/nodes/<node>` (a separate key, so a summary
refresh never rewrites the registration), through the lease-bound agent endpoint with the same
tenure check as an observed write. It is **advisory** (owner decision O1, 2026-11-03): it
is a summary (`src/chunk_summary.zig`, `docs/swarm.md`), not an accounting. It is never in a
compare set, so a stale or missing record can only make a placement less local, never wrong
on fit or spread. `sample` is the bottom-K sketch of the tree's chunk keys as hex, 24 digits
per entry (an 8-byte key and a 4-byte size, little endian); `filter` is hex. At most
`summary_trees_max` trees; trees that do not fit count in `omitted`. The scheduler reads the
record of each candidate node and ranks by `locality_bytes` (after fit and spread, before least
allocated); the decision records the number and the record's `mod_revision`.

The scheduler does **not** watch `/node-store/`: it reads the prefix fresh each pass, at the
revision its other reads use, so a summary refresh never wakes it. It reads tolerantly: a record
that is malformed or of a version newer than 1 is skipped (and counted), and that node scores 0
locality; one bad record never stops placement. The endpoint refuses any `v` but 1 (`ZC-E0104`).

## `/pulls/<node>/<tree>`: what a pull moved, by source (C2 slice 7)

```json
{ "v": 1, "node": "node1", "tree": "b3:51aa9c03…",
  "registry_bytes": 1048576,
  "peer_bytes": [{"peer": "node2", "bytes": 2097152}],
  "cached_bytes": 0, "started_at_ms": 1700000000000, "finished_at_ms": 1700000004000,
  "bad_peers": ["node3"] }
```

Written by the agent of `<node>`, for `zcube stats pull` and the console only (owner decision O6,
2026-11-04). It is **statistics**: no controller reads it, it is in no compare set, and a missing
or stale record changes nothing else. Unlike `/nodes/<node>` it is **not lease-bound**, so the
numbers outlive the node. One record per (node, tree); a later pull of the same tree replaces it.
`registry_bytes` and each peer's `bytes` are chunk bytes fetched; `cached_bytes` is what the node
already held; `bad_peers` names peers struck for a chunk that did not match its hash (ZC-W0601).
The record is written only for a pull that finished. The write is a tenure-checked agent write
(`POST /v1/agent/nodes/{node}/pulls`, docs/api.md), so a replaced agent cannot write one.

Data path: `zcube-agent fetch --report FILE` writes the record to `<container dir>/pull.json`
when the pull succeeds; the agent publishes it on its next step and removes the file
(docs/agent.md). A malformed record, or one for another node, is dropped.

Retention (`src/pull_retention.zig`): the newest `pulls_per_node_max` (100) per node, none older
than `pull_age_ms_max` (30 days) by `finished_at_ms`. The replica controller runs a pass every
`pulls_interval_ms` (5 minutes) and, when a pass stopped at `pulls_pages_per_pass_max` pages, again
at once from where it stopped, wrapping to the start when a page ends the prefix. A pass prunes the
part of each node's run it read: a dropped record always has `pulls_per_node_max` newer ones in
the whole set, so a partial run is safe and repeated passes converge. The `retention` role deletes
with a `mod_revision` compare and never puts. A malformed record is left alone and counted, never
deleted by guess. A pass that fails does not fail the step: it is retried after `pulls_retry_ms`
and the server says so once. `GET /v1/stats/pull` reads tolerantly (`skipped`) and at most
`pulls_read_max` (500) records (`truncated`).

## `/observed/<node>/<replica>`: what the agent reports

```json
{ "v": 1, "replica": "hello-9", "node": "node1", "generation": 4,
  "status": "stopped",
  "exit": {"kind": "start_failed"},
  "diagnostic": { "code": "ZBX-E0410", "severity": "error", "blame": "user",
                  "summary": "no tree with that digest", "causes": ["..."], "while": ["..."],
                  "context": {}, "fixes": [{"sentence": "...", "command": "..."}],
                  "omitted": {"causes": 0, "while": 0, "context": 0, "fixes": 0} },
  "started_at_ms": 1761349990000, "reported_at_ms": 1761350000000 }
```

- `started_at_ms` is when the container last started, as the runtime knows it. It is what a
  replica's age is measured from. `reported_at_ms` moves on every status change and says when the
  agent last learned something, which is not the same thing. Absent until the container has
  started (a `start_failed` never sets it).
- `status` is `starting`, `running` or `stopped`.
- `exit` is present when `stopped`: `{"kind": "exited", "code": 0}`, `{"kind": "signaled",
  "signal": 9}`, `{"kind": "oom"}`, `{"kind": "pid_limit"}`, `{"kind": "start_failed"}`,
  `{"kind": "lost"}`: the runtime's `ExitReason`; and `{"kind": "refused"}` (B5 slice 2, jobs only):
  the node's trust policy refused the run, nothing was started, and `diagnostic` is the
  `ZBX-E0905` (or `ZBX-E0906`). In a replica's `/observed` record it is never valid: the agent
  endpoint refuses such a report (ZC-E0104) and a reader takes the row as malformed (ZC-E0301).
- **`diagnostic` is where an observed-state diagnostic lives.** It is a complete diagnostic in
  the JSON shape of DIAGNOSTICS.md (the `Diagnostic` of `src/diagnostic.zig`), embedded in the
  record that it explains. Present for `start_failed` (the runtime's own, possibly `ZBX-`),
  and for agent-side failures (a `ZC-05xx` code). Absent for a clean state. Its code may belong
  to either product's registry; readers use the text, not a registry.
- `generation` echoes the replica's generation the agent acted on.
- `tenure` (C1 slice 6, optional): the `/nodes/<node>` revision the agent registered at. The
  agent endpoint writes the record only if `/nodes/<node>` is still at that revision (one compare),
  so an agent whose lease ran out cannot write.
- `assignment` (C1 slice 6, optional): the `mod_revision` of `/assigned/<node>/<id>` the agent
  acted on, the placement epoch. A controller acts on an observation only if `tenure` and
  `assignment` are current and `/node-status/<node>` is `ready`.

Lifetime: until the agent or the node controller removes it. One writer per key (the node's agent), written on every status change, not on a timer, so the
store's revision tells when the node last learned something. Written with one compare, never
last-write-wins: every record the agent writes carries its current `tenure`, and the agent
endpoint writes it only while `/nodes/<node>` is still at that revision (else `ZC-E0510`), so a
replaced or fenced agent cannot overwrite what its successor observed.

## `/decisions/<id>`: one controller decision

```json
{ "v": 1, "id": "1761350000123-rc01-0007", "at_ms": 1761350000123,
  "actor": "replica-controller", "action": "create_replica",
  "subject": {"kind": "replica", "name": "hello-9"},
  "reason": "service hello wants 3 replicas and 2 exist",
  "cause": {"kind": "observed", "key": "/observed/node1/hello-3", "revision": 412},
  "cause_diagnostic": { "...": "copy of the diagnostic, if the cause carries one" },
  "cause_evidence": { "status": "stopped", "exit": {"kind": "signaled", "signal": 9} } }
```

`Decision` v3 (C2 slice 5) adds three optional members to a placement: `locality_bytes`, the bytes
of the replica's image tree the chosen node already held by the node's summary,
`node_store_revision`, the `mod_revision` of the `/node-store/<node>` the scheduler read (non-zero
whenever `locality_bytes` is; 0 when the node had none), and `read_revision`, the revision of the
world the scheduler decided over (the simulators' L1 check judges only rivals no newer than it).
A decision is written `v: 3` only when it carries `locality_bytes` (every placement of C2) and
`v: 2` otherwise, so C2 only breaks a C1 reader for placements. **Rolling a store back from C2 to
C1 is unsupported**: a C1 reader refuses a v3 decision as too new.

`cause_evidence` (C1, optional, at most `decision_evidence_bytes_max` = 1024 bytes) holds the
fields of the cited key's value that the decision acted on, as the controller read them, so
`why` can show what justified the action after the key has changed or been compacted. A
decision is immutable once written.

The scheduler's `hold_pending` cites the replica's `/replicas` key and its `cause_evidence` is
not fields of that key but the shortfall it computed: `{"need":{"cpu_millis":N,"memory_bytes":N},
"<reason>":["node",…],"cpu_short":{"node":by,…},"memory_short":{"node":by,…},"omitted":N}`, where
`<reason>` is one of `unknown_node`, `lost`, `fenced`, `no_status`, `older_tenure`,
`audit_open`, `over_capacity` (only those that occur appear) and `omitted` counts nodes that did
not fit in the byte bound. A new `hold_pending` is written only when the *shape* changes (per
node: why it is excluded, or which resource it lacks), not when the amounts do.

`id` is `<at_ms, 13 digits>-<controller instance, 4 hex>-<counter, 4 digits>`: sortable by
time, unique without coordination. Written in the same transaction as the action it records,
so an action and its record exist together or not at all.

**How a decision references a cause** (`cause`, one of; `lease_expired` exists because a lost node
leaves no observed record for an `observed` cause to point at):

| `kind` | Fields | Meaning |
| --- | --- | --- |
| `decision` | `id` | this was a consequence of another decision |
| `observed` | `key`, `revision` | the controller reacted to this observed record, at this revision |
| `desired` | `key`, `revision` | it reacted to a change of desired state (an `apply`) |
| `lease_expired` | `key`, `lease`, `ttl_ms`, `revision` | the key was deleted because its lease ran out: `key` is the deleted key (a node's `/nodes/<node>`), `lease` the lease id, `ttl_ms` its ttl, `revision` the revision of the delete |
| `resync` | none | periodic resync found drift; the root of a chain |

`zcube why` starts at a subject's newest decision and follows `cause` until a `desired`,
`observed`, `lease_expired` or `resync` terminal, rendering each step. The `key` and `revision` pin the exact
version of the record the controller saw. Because history older than the compaction point is
gone, and decisions outlive it, **a decision whose cause carries a diagnostic also embeds a
copy of it** in `cause_diagnostic`. The link stays for navigation and the copy for survival;
the cost is a couple of kilobytes per such decision.

### Apply decisions, and decisions about a service

**An apply is a decision.** The API writes one, in the same transaction as the service put:
`actor` `api`, `action` `apply`, `subject` the service, with a one-line summary of what changed:

```json
{ "v": 1, "id": "1761350000123-api0-0001", "at_ms": 1761350000123,
  "actor": "api", "action": "apply", "subject": {"kind": "service", "name": "hello"},
  "reason": "alex@laptop applied hello (request r-0001a4f)",
  "change": "replicas 3 → 5",
  "cause": {"kind": "desired", "key": "/services/hello"} }
```

- `change` is that one line (`"created"`, `"replicas 3 → 5"`, `"image b3:51aa… → b3:7c02…"`,
  `"replicas 3 → 5, env changed"`; it never contains an `env` value). It exists because the
  previous generation's spec is gone once history is compacted, so neither the console nor
  `zcube apply` could say afterwards what an old apply changed. It is present only on `apply`
  decisions.
- This decision's `cause` has no `revision`: a transaction cannot know the revision it will take.
  A reader takes it from the decision key's own `mod_revision`, which is the revision of the
  apply (the decision and the service were written together). Decisions that react to the apply
  later write `{"kind": "desired", "key": "/services/hello", "revision": <that revision>}`.

**Service-level decisions.** A decision's subject may be a service, not only a replica or a node.
`zcube why service x` needs them or the chain for a service starts nowhere. The replica
controller records its choices about a service's replica set with the service as subject:
`scale_up`, `scale_down`, `replace_replica` and `hold_failed_replica`, each linking by `cause` to
the observed record or decision that provoked it. A decision about one replica (`create_replica`,
`stop_replica`, `mark_replica_lost`) keeps that replica as its subject, with a `cause` that points
at the service-level decision above it, so the two chains join.

**Job decisions (B1).** The job controller's decisions have a job as subject
(`/decisions-by-subject/job/<name>/<id>`), and their actions are written in snake_case like every
other: `job_created` (the run and its pending status exist; the rule "a run is created once"
rests on it, judged per incarnation by the index entry's `create_revision`), `job_placed`,
`job_running`, `stop_job`, `end_job`, `hold_contradictory_job` (ZC-E0307), `hold_unmapped_ending`
(ZC-B0004), `hold_unreadable_job` (a job record, run, status or the node's report of the run that does not decode is skipped, once per revision; its cause
is the existing ZC-E0301 or ZC-E0303; B2 slice 2. An unreadable report holds the run only while it can do nothing else: a cancel still writes its stop, and a node lost past the grace still ends the run, `failed unreachable` when the run was running and `failed unknown` otherwise) and `drop_report` (ZC-W0307: a report that arrived after the job ended, which changes
nothing). A decision that holds or drops is not repeated for the same record revision.
(`mark_replica_lost` for a replica whose node was lost points at the node's `mark_lost` instead, and
the `replace_replica` it provokes at it, so `why` on the replacement, a new id, reaches the lease.)
A decision with a service as subject is indexed under `/decisions-by-subject/service/<name>/<id>`
like any other.

## `/decisions-by-subject/<kind>/<name>/<id>`: the index for `zcube why`

`<kind>` is `service`, `replica` or `node`; `<name>` is the service or replica id or node name.

```json
{ "v": 1, "id": "1761350000123-rc01-0007", "at_ms": 1761350000123,
  "action": "create_replica", "summary": "created hello-9 on node1" }
```

Written in the same transaction as the decision. A prefix read of `.../<kind>/<name>/` returns
a subject's history in time order without fetching decisions; the full record is a `get` away.

## Retention of decisions

Open (HANDOFF). Recommendation: keep the newest **200 decisions per subject, and at most 7
days**, whichever is fewer; the controller deletes the oldest decision and its index entry in
the transaction that writes a new one for that subject. When a subject is deleted, its
decisions stay for 24 hours so `zcube why` can still say why a replica went away. The numbers
are constants in `src/constants.zig`, not user configuration, until someone needs them to be.

C1 changes this rule: decisions on a live subject's current chain are never evicted
(`authority.md` section 5): for each live subject its newest decision of each action is a root,
retention walks each root's chain and pins every decision on it, and only an unpinned decision
beyond the budget is evicted. A deleted subject's decisions are no longer roots and stay 24 hours.
Implemented in `src/retention.zig`. A pass computes the pinned set only when it has candidates,
reading through a 1 MiB scratch region and bounded by `retention_pinned_max`; if a walk exceeds
that bound or meets a malformed record, the pass drops nothing for live subjects (fail safe).
A deleted subject's summaries go with its last decisions.
A chain that needed an evicted decision is reported `truncated` by `zcube why`, with its reason.

## `/assigned/<node>/<replica>`: the placement (C1 slice 3)

```json
{"v":1,"replica":"hello-1","service":"hello","requests":{"cpu_millis":250,"memory_bytes":134217728},"reason":"node1 is the only node, and it fits 250m CPU and 128 MiB"}
```

Written by the scheduler, which is the only role that removes it; it releases the node's
allocation in the same transaction. An agent long-polls its own `/assigned/<node>/` prefix, so
fan-out is the replicas on the node, not all replicas. The key's `mod_revision` is the replica's
**placement epoch**. Lifetime: until unassigned. The value is under 256 bytes.

`requests` is what the scheduler **resolved** the replica to need: its `limits` where the
service sets them, else a default the scheduler states in the decision that placed it. A node's
used capacity is `/allocations/<node>` (below), the sum of the `requests` of its assignments, so
a replica with no limits does not count as zero.

## `/allocations/<node>`: the accounting (C1 slice 3)

```json
{"v":1,"allocated":{"cpu_millis":250,"memory_bytes":134217728},"count":1,"node_revision":3}
```

Written by the scheduler. The authoritative sum of the `requests` of every assignment on the node,
their count, and the `/nodes/<node>` revision whose capacity it was checked against. Every
placement compares it at the revision read, so two placements planned on the same revision cannot
both commit (no phantoms). Lifetime: while the node exists.

## `/audit/allocations/<node>`: an open finding (C1 slice 4)

```json
{"v":1,"recorded":{"allocated":{"cpu_millis":250,"memory_bytes":134217728},"count":1},"reconstructed":{"allocated":{"cpu_millis":0,"memory_bytes":0},"count":0},"revision":9,"decision":"1761350000123-0001-0007"}
```

Written by the allocation auditor when the sum it reconstructs from `/assigned/<node>/` differs
from `/allocations/<node>`, both read at `revision`. While it exists the scheduler places nothing
on the node (its absence is in the placement compare set). It never repairs. Lifetime: until a
later audit finds the node consistent, when the auditor deletes it with an `audit_clear` decision.

**The repair** (`zcube repair allocations <node> --confirm`, `POST /v1/repair/allocations/<node>`)
is the scheduler's, run in the request (role `scheduler`, actor `scheduler`): one transaction
compares `/allocations/<node>` and this finding at the revision the tally was rebuilt at (every
placement and release rewrites `/allocations/<node>`, so that compare also catches an assignment
the scheduler changed meanwhile), puts the rebuilt tally into `/allocations/<node>` and writes a
`repair_allocation` decision that cites the finding's `decision`. It leaves the finding in place; the auditor's next pass clears it.

## `/node-status/<node>`: the node controller's judgement (C1 slice 3)

```json
{"v":1,"state":"fenced","tenure":3,"at_ms":10,"decision":"1761350000123-0001-0008"}
```

Written by the node controller. `state` is `ready`, `lost` or `fenced`; `tenure` is the
`/nodes/<node>` revision it judged; `decision` is the decision that set it. Lifetime: until the
node is removed.

## `/decision-summaries/<kind>/<name>/<action>/<cause-kind>`: repetition counted (C1 slice 4)

```json
{"v":1,"count":142,"first_at_ms":1,"last_at_ms":2,"newest":"1761350000123-0001-0009"}
```

for example `/decision-summaries/service/hello/replace_replica/observed`. A projection over
immutable decisions, updated by the actor in the transaction of each decision it counts, and never
a cause: `why` shows it beside a chain, not as a step. `<action>` is at most 48 bytes. Lifetime:
with its subject.

## Jobs (B1 slice 1)

A job is its own object: it runs once, on one node, to an end that is recorded, and is never
started twice. Design: `docs/briefs/b1.md`; owner's answers: `docs/decisions/2026-11-05-b1-owner-answers.md`.
The **run id** is `<name>-job` (at most 52 bytes): its last segment is not decimal, so it is never
a replica id (`<service>-<n>`), and it is a valid container name. Job names follow the service
name rule (48 bytes).

### `/jobs/<name>`: the desired job (API)

```json
{"v":1,"name":"train-7","image":"b3:51aa9c03","source":"","command":["run","--x"],
 "env":[["MODE","fast"]],"limits":{"cpu_millis":500,"memory_bytes":268435456,"pids":64},
 "deadline_ms":600000,"retries":0,"labels":[["org","acme"]],"grace_ms":5000,
 "input_env":"BOTPIKE_INPUT","input_digest":"sha256:…","input_bytes":1024,
 "submit_by_ms":1761350600000,"created_at_ms":1761350000000,"applied_by":"alice",
 "cancel_requested":{"at_ms":1761350100000,"by":"alice"}}
```

The spec is immutable. `cancel_requested` is the one member that changes (set once). The input is
never here, only its digest and size. `retries` is 0 (a larger value is `ZC-E0130`).
`relay` (B3, optional, additive at the same version) is `{"name":"botpike","address":"HOST:PORT"}`:
the name the job asked for and the address the server's configuration gave it at admission.
`signatures` (B5, optional, additive at the same version) is an array of at most
`job_signatures_max` (4) DSSE envelopes, each 1 to `job_signature_bytes_max` (2048) bytes of
printable ASCII (one line of `zbx trust export`), as submitted; absent when the job has none. At most
`job_labels_max` (6) labels, `job_command_words_max` (64) command words, `env` of at most
`job_env_bytes_max` (8 KiB). Written with its `/job-input/` and `/job-admission` in one transaction.

**Upgrade note (B5 `signatures`).** Every reader of `/jobs/` and `/job-runs/` decodes with unknown
members ignored, so an older build reads these records, but it drops what it ignores:

- A pre-B5 server serving `POST /v1/jobs/{name}/cancel` decodes the job, sets `cancel_requested` and
  writes it back without `signatures`. After the next upgrade, resubmitting the same signed body
  answers `409` ZC-E0131 for a job the client never changed.
- A run made by a pre-B5 job controller has no `signatures`. Once the node's check of B5 slice 2
  exists, an agent with a trust policy refuses such a run although its job was signed.
- A pre-B5 server answers a body with `signatures` `400` ZC-E0104 (unknown member).
- A pre-B5 agent ignores the run's `signatures` and runs the job unchecked, which is safe in slice 1.
- A slice-1 server does not know the slice-2 agent's exit kind `refused` (`/observed`) and refuses
  that report, so a refused run is never ended; it also ignores `trust_policy` in a registration.

Order: upgrade every server first, and finish the rollout before submitting signed jobs; never serve
cancels from a server rolled back past B5; agents may be upgraded in any order until slice 2, and
after it, before any agent is given a trust policy. For slice 2: every server first, then the agents
(B5 slice 2, docs/decisions/2026-11-13-b5-slice2-agent-check.md).

### `/job-input/<name>`: the input (API)

`{"v":1,"base64":"…"}`: at most `job_input_bytes_max` (64 KiB) of UTF-8 without NUL, held base64
encoded so that it always fits a store value. Written once with the job, read only through the agent
endpoint for the node the run is assigned to, deleted by retention once the job has ended. Never
returned by a public route and never shown by the console.

### `/job-admission` and `/job-endings`: the aggregates

`/job-admission`: `{"v":1,"admitted":N,"hours":[{"hour":H,"count":C},…]}`: jobs ever created, and
creations per hour over the last `job_admission_window_h` (73) hours, `hour` increasing. Written by
every create, which compares it, so creates are serialised and a predicate over the set (jobs not
ended: `jobs_max`; jobs created in the window: `job_admitted_window_max`) is never missed
(authority.md, "Predicates over sets"). `/job-endings`: `{"v":1,"ended":N}`, written by every terminal
status, which compares it. Neither is deleted.

### `/job-runs/<name>`: the run (job controller)

`{"v":1,"id":"train-7-job","job":"train-7",` the spec's `image`, `source`, `command`, `env`,
`limits`, `deadline_ms`, `grace_ms`, `labels`, `input_env`, `input_digest`, `input_bytes`, `relay`
(B3, as in the job), `signatures` (B5, as in the job),
`"start_by_ms":…,"created_at_ms":…,"stop":{"cause":"cancel","at_ms":…}}`. At most
`job_run_bytes_max` (16 KiB). Created once, with its status. `stop` is set at most once and never
removed; its `cause` is `cancel`, `unreachable` or `not_started`. From the revision of the `stop`,
nothing places or claims the run. `start_by_ms` is creation plus `deadline_ms` on the server's clock.

### `/job-status/<name>`: how it is going and how it ended (job controller)

`{"v":1,"state":"failed","node":"node1","epoch":12,"tenure":7,"started_at_ms":…,"ended_at_ms":…,
"end":{"kind":"failed","cause":"deadline"},"stop_cause":"deadline","diagnostic":{…},
"decision":"…","reported_at_ms":…}`.

- `state`: `pending`, `placed`, `running`, then one terminal state: `exited`, `failed`,
  `cancelled`. A terminal status is written once and never changes (I8a).
- `end` is present exactly when the state is terminal, with `ended_at_ms`. `exited` carries exactly
  one of `code` and `signal`; `failed` carries `cause`, one of `oom`, `pid_limit`, `start_failed`,
  `deadline`, `fenced`, `unreachable`, `not_started`, `refused` (B5 slice 2: the node's trust policy
  refused the run; never retried or placed again), `unknown`; `cancelled` carries nothing. A
  record that breaks this is `ZC-E0301` on read.
- `stop_cause` (`cancel`, `deadline`, `fence`, `not_started`, `unreachable`): why the agent stopped
  the run, when it did. The ending follows it, never the exit alone.
- `epoch` and `tenure` are those of the claim; node loss is judged by the run's tenure.
- `diagnostic`: a `ZC-` diagnostic, as in `/observed`, when the job failed.

### `/job-observed/<node>/<name>`: what the agent reports of a run (that node's agent)

`{"v":1,"run":"train-7-job","node":"node1","tenure":7,"assignment":12,"status":"claimed",
"exit":{"kind":"exited","code":0},"stop_cause":"cancel","diagnostic":{…},"started_at_ms":…,
"reported_at_ms":…}`. Its own record kind, not `Observed`. `status` is `claimed` (written before the
run is started, comparing the agent's tenure and the run's revision), `running` or `stopped`. A run
has at most one claim, ever. A `stopped` report carries `exit` and no other status does, and a
`claimed` report has no `started_at_ms`; a record that breaks either is malformed (ZC-E0301).
Admissible under the three conditions of authority.md §3.

### `/assigned/<node>/<name>-job`: the placement of a run (scheduler)

`Assigned` version 2 adds `job` (the job name); a run's `service` is empty, and a replica's
assignment is still written as version 1. Every reader of `service` treats an assignment with a
`job` as belonging to no service. The epoch is the key's `mod_revision`, as for a replica. The
agent reads the run's `relay` (B3) from the run record it already fetches for the claim; the
assignment itself carries no address.

## Compare sets

Each transaction carries compares on every fact it rests on (`src/compare_sets.zig`): a placement
has 6 (the replica, its assignment absent, the node, its status, its allocation, no open finding),
a release 2, a move 8 (a placement on the new node and a release on the old), and an observed
write 1 (`/nodes/<node>` at the tenure revision). Each is asserted against
`store_txn_compares_max`.
