# Keys and values

The key layout of HANDOFF.md, with value shapes. Keys are `/`-separated absolute paths of
printable ASCII, at most 512 bytes (`src/store.zig`, `key_problem`). Values are JSON objects,
at most 256 KiB, because the API, the agents and `zcube why` all speak JSON and diagnostics are
JSON (DIAGNOSTICS.md). Service files are ZON; `zcube apply` converts them to the JSON below on
the client. Every value carries `"v": 1`, so a field can be added later without guessing which
writer produced a record. Status: the key layout and value shapes are **approved as of
2026-10-26**, together with the 11 items of `docs/api.md` ("What the console needs from the
contracts"), which this file now records. They are documented shapes only: no controller, API
handler or agent writes them yet, so nothing here is implemented beyond the store itself.

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
counter that makes replica ids unique forever (below); only the replica controller moves it, in
the same transaction that creates the replica.

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
`node` is empty until the scheduler assigns it (C0: always the one node).

`requests` is what the scheduler **resolved** the replica to need: its `limits` where the
service sets them, else a default the scheduler states in the decision that placed the replica.
A node's used capacity is the sum of the `requests` of the replicas assigned to it, so a replica
with no limits no longer counts as zero. Both numbers are always present once the replica has
been scheduled; they are absent only while `node` is empty.

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
  "capacity": {"cpu_millis": 4000, "memory_bytes": 8589934592}, "labels": [] }
```

Written by the agent with `lease` set to the lease it keeps alive. When the lease ends the key
is deleted by the store, and that delete event is how lost nodes are detected (C1). Capacity is
declared by the agent's configuration (see the open questions in `docs/contracts-review.md`).

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
  `{"kind": "lost"}`: the runtime's `ExitReason`.
- **`diagnostic` is where an observed-state diagnostic lives.** It is a complete diagnostic in
  the JSON shape of DIAGNOSTICS.md (the `Diagnostic` of `src/diagnostic.zig`), embedded in the
  record that it explains. Present for `start_failed` (the runtime's own, possibly `ZBX-`),
  and for agent-side failures (a `ZC-05xx` code). Absent for a clean state. Its code may belong
  to either product's registry; readers use the text, not a registry.
- `generation` echoes the replica's generation the agent acted on.

One writer per key (the node's agent), written on every status change, not on a timer, so the
store's revision tells when the node last learned something. Written without compare (last
write wins): the agent is the only source of truth for what it observed.

## `/decisions/<id>`: one controller decision

```json
{ "v": 1, "id": "1761350000123-rc01-0007", "at_ms": 1761350000123,
  "actor": "replica-controller", "action": "create_replica",
  "subject": {"kind": "replica", "name": "hello-9"},
  "reason": "service hello wants 3 replicas and 2 exist",
  "cause": {"kind": "observed", "key": "/observed/node1/hello-3", "revision": 412},
  "cause_diagnostic": { "...": "copy of the diagnostic, if the cause carries one" } }
```

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

## One layout observation for the owner

An agent needs only its own node's replicas, but `/replicas/<service>/<id>` is keyed by
service, so a prefix watch cannot select one node: every agent would watch all replicas and
filter, which is O(agents × replicas) of wasted fan-out. For C0 (one node) this does not
matter. For C1 I would propose an index key **`/assigned/<node>/<replica>`**, written by the
scheduler in the same transaction that sets `node`, that the agent watches. It is an addition
to HANDOFF's suggested layout, so it needs your approval; the alternative is server-side
filtering of the watch by the `node` field, which keeps the layout but makes the API server
inspect values.
