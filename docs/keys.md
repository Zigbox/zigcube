# Keys and values

The key layout of HANDOFF.md, with value shapes. Keys are `/`-separated absolute paths of
printable ASCII, at most 512 bytes (`src/store.zig`, `key_problem`). Values are JSON objects,
at most 256 KiB, because the API, the agents and `zcube why` all speak JSON and diagnostics are
JSON (DIAGNOSTICS.md). Service files are ZON; `zcube apply` converts them to the JSON below on
the client. Every value carries `"v": 1`, so a field can be added later without guessing which
writer produced a record. Status: **proposed, not final** until the owner approves the two
contracts; nothing here is implemented beyond the store itself.

Names: a service name is a hostname label (lowercase letters, digits, `-`), at most 48 bytes,
so that a replica id fits Zigbox's 63-byte container-name rule. A node name follows the same
rule at 63 bytes.

## `/services/<name>`: desired service

```json
{ "v": 1, "name": "hello", "image": "b3:51aa9c03", "replicas": 3,
  "command": ["sh", "-c", "while true; do sleep 1; done"],
  "env": [["KEY", "value"]], "limits": {"cpu_millis": 500, "memory_bytes": 134217728},
  "generation": 4, "next_replica": 17 }
```

Written by the API on `apply`. `generation` increases on every change of the spec, so a
decision can say which version it acted on. `next_replica` is the counter that makes replica
ids unique forever (below); only the replica controller moves it, in the same transaction that
creates the replica.

## `/replicas/<service>/<id>`: desired replica

`<id>` is `<service>-<n>` with `n` from `next_replica`, never reused: a replacement for
`hello-3` is `hello-9`, so an old container and its observed record can never be mistaken for
the new one. The id is also the container name and the `zcube.replica` label.

```json
{ "v": 1, "id": "hello-9", "service": "hello", "generation": 4, "node": "node1",
  "image": "b3:51aa9c03", "command": ["sh", "-c", "..."], "env": [], "limits": {} }
```

The replica copies what it needs from the service at creation, so editing the service does not
change a running replica; the controller replaces replicas whose `generation` is behind.
`node` is empty until the scheduler assigns it (C0: always the one node). **Deleting the key
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
  "diagnostic": { "code": "ZBX-E0501", "severity": "error", "blame": "user",
                  "summary": "image not found", "causes": ["..."], "while": ["..."],
                  "context": {}, "fixes": [{"sentence": "...", "command": "..."}],
                  "omitted": {"causes": 0, "while": 0, "context": 0, "fixes": 0} },
  "reported_at_ms": 1761350000000 }
```

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

**How a decision references a cause** (`cause`, one of):

| `kind` | Fields | Meaning |
| --- | --- | --- |
| `decision` | `id` | this was a consequence of another decision |
| `observed` | `key`, `revision` | the controller reacted to this observed record, at this revision |
| `desired` | `key`, `revision` | it reacted to a change of desired state (an `apply`) |
| `resync` | none | periodic resync found drift; the root of a chain |

`zcube why` starts at a subject's newest decision and follows `cause` until a `desired`,
`observed` or `resync` terminal, rendering each step. The `key` and `revision` pin the exact
version of the record the controller saw. Because history older than the compaction point is
gone, and decisions outlive it, **a decision whose cause carries a diagnostic also embeds a
copy of it** in `cause_diagnostic`. The link stays for navigation and the copy for survival;
the cost is a couple of kilobytes per such decision.

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
