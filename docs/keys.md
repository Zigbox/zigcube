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
| `/allocations/<node>` | scheduler | C1 slice 3 |
| `/audit/allocations/<node>` | allocation auditor | C1 slice 4 |
| `/node-status/<node>` | node controller | C1 slice 4 |
| `/observed/<node>/<id>` | that node's agent (the node controller may delete) | C0 |
| `/decisions/…`, `/decisions-by-subject/…` | every role, in the transaction of the action | C0 |
| `/decision-summaries/…` | every role, in the transaction of the decision it counts | C1 slice 4 |

An agent writes only `/nodes/<its node>` and `/observed/<its node>/…`. One departure from
`authority.md`, recorded in `docs/DECISIONS.md`: a seventh role, `retention`, deletes expired
decisions and so may touch only the decision prefixes. `/services/<name>` is the API's alone:
the replica counter lives in `/replica-numbers/<service>` from slice 3, and `writers.zig`
refuses a put or delete of a service by any role but the API. `Service` v2 reads a legacy
`next_replica` to seed the counter and never writes it. The replica controller reads a counter
only with a `get` when it is about to create replicas for that service, never by listing, so the
number of counters bounds nothing.

## Versions

Every value has `"v"`. A reader accepts every version up to the one its release writes and
ignores members it does not know. `Observed` and `Decision` write `"v": 2` (they gained members
in C1); every other record writes `"v": 1`. Records C0 wrote (`"v": 1`) still read: the fixtures
in `src/testdata/c0_store.txt` were captured from a real C0 store. A value with a **newer**
version than the reader knows is refused with one line naming the key and both versions,
`ZC-E0303`, never as a malformed record.

Names: a service name is a hostname label (lowercase letters, digits, `-`), at most 48 bytes,
so that a replica id fits Zigbox's 63-byte container-name rule. A node name follows the same
rule at 63 bytes.

## `/services/<name>`: desired service

```json
{ "v": 1, "name": "hello", "image": "b3:51aa9c03", "replicas": 3,
  "command": ["sh", "-c", "while true; do sleep 1; done"],
  "env": [["KEY", "value"]], "limits": {"cpu_millis": 500, "memory_bytes": 134217728},
  "generation": 4, "next_replica": 17,
  "applied_by": "alex@laptop", "request_id": "r-0001a4f" }
```

Written by the API on `apply`. `generation` increases on every change of what a replica runs,
so a decision can say which version it acted on: the image, the command, `env` and `limits`.
**A change of `replicas` alone does not bump it** (owner, 2026-10-26): scaling from 3 to 5 must
not replace the three that run. The replica controller replaces replicas whose `generation` is
behind, and only a change of the replica's own inputs puts one behind. `next_replica` is the
counter that makes replica ids unique forever (below). From slice 3 it lives in
`/replica-numbers/<service>` (`{"next": N}`), which only the replica controller writes, in the
same transaction that creates the replica. It is **never deleted**: the key outlives the service
and its replicas (one small key per service name ever applied), so a re-apply continues the
numbering. A legacy `next_replica` on the service seeds it, and so does one past the highest
live replica number, whichever is larger, only when the key is absent.

`applied_by` (the authenticated actor) and `request_id` (the API request that wrote this
version, the same id as in `--verbose` output and bundles) say who changed the service last
and let `zcube why` end its chain at a person and a request. A later `source` (git commit, file
digest) is reserved and not written yet.

**`env` values are secrets.** They are stored here, but the API never sends them to a
read-only token: it sends the names only (`"env": [["KEY", null]]` in the API's JSON, a null
value). A token that may write sees the values. Nothing outside the API, the replica copy below
and the agent reads them, and bundles redact them (DIAGNOSTICS.md).

## `/replicas/<service>/<id>`: desired replica

`<id>` is `<service>-<n>` with `n` from `next_replica`, never reused: a replacement for
`hello-3` is `hello-9`, so an old container and its observed record can never be mistaken for
the new one. The id is also the container name and the `zcube.replica` label.

```json
{ "v": 1, "id": "hello-9", "service": "hello", "generation": 4, "node": "node1",
  "image": "b3:51aa9c03", "command": ["sh", "-c", "..."], "env": [], "limits": {},
  "requests": {"cpu_millis": 500, "memory_bytes": 134217728} }
```

The replica copies what it needs from the service at creation, so editing the service does not
change a running replica; the controller replaces replicas whose `generation` is behind.
`node` is empty until the scheduler assigns it (C0: always the one node). **From C1 slice 3
the replica controller writes no placement:** `/assigned/<node>/<id>` (below) replaces `node`.

`requests` is what the scheduler **resolved** the replica to need: its `limits` where the
service sets them, else a default the scheduler states in the decision that placed the replica.
A node's used capacity is `/allocations/<node>` (below), the sum of the `requests` of the replicas assigned to it, so a replica
with no limits no longer counts as zero. Both numbers are always present once the replica has
been scheduled; they are absent only while `node` is empty.

**A replica whose start failed through the user's fault is held, not replaced** (owner,
2026-10-26). When `/observed/<node>/<replica>` says `start_failed` with a diagnostic whose blame
is `user` (a digest that is not in the store, `ZBX-E0501`), the replica controller leaves the
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
  "capacity": {"cpu_millis": 4000, "memory_bytes": 8589934592}, "labels": [] }
```

Written by the agent with `lease` set to the lease it keeps alive. When the lease ends the key
is deleted by the store, and that delete event is how lost nodes are detected (C1). The key's
`mod_revision` at registration is the node's **tenure revision** (`authority.md` section 3). Capacity is
declared by the agent's configuration (see the open questions in `docs/contracts-review.md`).

## `/observed/<node>/<replica>`: what the agent reports

```json
{ "v": 1, "replica": "hello-9", "node": "node1", "generation": 4,
  "status": "stopped",
  "exit": {"kind": "start_failed"},
  "diagnostic": { "code": "ZBX-E0501", "severity": "error", "blame": "user",
                  "summary": "image not found", "causes": ["..."], "while": ["..."],
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
  `{"kind": "lost"}`: the runtime's `ExitReason`.
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
store's revision tells when the node last learned something. Written without compare (last
write wins): the agent is the only source of truth for what it observed.

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
at the service-level decision above it, so the two chains join. A decision with a service as
subject is indexed under `/decisions-by-subject/service/<name>/<id>` like any other.

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
A chain that needed an evicted decision is reported `truncated` by `zcube why`, with its reason.

## `/assigned/<node>/<replica>`: the placement (C1 slice 3)

```json
{"v":1,"replica":"hello-1","service":"hello","requests":{"cpu_millis":250,"memory_bytes":134217728},"reason":"node1 is the only node, and it fits 250m CPU and 128 MiB"}
```

Written by the scheduler, which is the only role that removes it; it releases the node's
allocation in the same transaction. An agent long-polls its own `/assigned/<node>/` prefix, so
fan-out is the replicas on the node, not all replicas. The key's `mod_revision` is the replica's
**placement epoch**. Lifetime: until unassigned. The value is under 256 bytes.

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
later audit finds the node consistent.

## `/node-status/<node>`: the node controller's judgement (C1 slice 4)

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

## Compare sets

Each transaction carries compares on every fact it rests on (`src/compare_sets.zig`): a placement
has 6 (the replica, its assignment absent, the node, its status, its allocation, no open finding),
a release 2, a move 8 (a placement on the new node and a release on the old), and an observed
write 1 (`/nodes/<node>` at the tenure revision). Each is asserted against
`store_txn_compares_max`.
