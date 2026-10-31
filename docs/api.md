# HTTP API proposal for the web console

**Status: Approved by the owner on 2026-10-26; the server implements it.** This is the read-only API the
console ([console.md](console.md)) needs, written against HANDOFF's decisions and the approved
`Store` and `Runtime` contracts. The browser mock in `web/mock/` implements exactly what is
written here, so the console is already built against it. Nothing in this file changes `Store`
or `Runtime` by itself; the places where it would need to are listed in
[What the console needs from the contracts](#what-the-console-needs-from-the-contracts) and
each is an **Ask first**. The owner approved this document as written (endpoints, conventions, the three `ZC-E01xx` codes and the 11 items below); the `Store`, key-layout and decision-schema changes land in a separate C0 slice, not here.

## Decisions taken from HANDOFF

- HTTP/1.1 and JSON. No WebSocket, no server push. The console follows changes with the
  provisionally approved long-poll watch.
- Every failure is a DIAGNOSTICS.md diagnostic object. A client never sees a bare error string.
- Every request gets a request ID.
- The console is served by `zcube-server` itself (`GET /` and `/console/*`, later embedded with
  `@embedFile`). It talks to `/v1/*` on the same origin, so there is no CORS.

## Conventions

| | |
| --- | --- |
| Base path | `/v1` |
| Methods | The console uses `GET` only. Writes are for the CLI: see [Writes](#writes-approved-2026-10-27). |
| Bodies | `application/json`, UTF-8. Values are the JSON records of [keys.md](keys.md), unchanged. |
| Request ID | The server assigns one to every request and returns it in the `X-Request-Id` response header, on success and failure. A client may send its own `X-Request-Id` (`[A-Za-z0-9-]`, 8 to 64 bytes); the server then uses it. Otherwise the id is `r-<start>-<counter>`: the start part is the server's start time (so no two starts, or servers, repeat an id) and the counter is per start. The CLI prints it with `--verbose`; bundles include it. |
| Auth | Out of scope here. SPEC says tokens are scoped; the console needs a read-only scope. A missing or insufficient token must be a diagnostic like any other. |
| Versioning | The path carries the major version. Additive fields are not a new version, so clients ignore unknown fields. |

### Errors

A failed request has a non-2xx status and this body:

```json
{
  "request_id": "r-5f3a91c2-0001a4f",
  "diagnostics": [
    { "code": "ZC-E0201", "severity": "error", "blame": "external",
      "summary": "can't reach the store backend",
      "causes": ["connection refused", "postgres at 127.0.0.1:5432 is not accepting connections"],
      "while": ["reading desired state for the request"],
      "context": {"backend": "postgres"},
      "fixes": [{"sentence": "start it", "command": "sudo systemctl start postgresql"}],
      "omitted": {"causes": 0, "while": 0, "context": 0, "fixes": 0} }
  ]
}
```

The diagnostic is the JSON form of DIAGNOSTICS.md, field for field (`src/diagnostic.zig`
already holds the data). `diagnostics` is an array because a command may report several; the
console renders them in order. The HTTP status follows the blame of the first one:

| `blame` | Status |
| --- | --- |
| `user` | `400` bad request, `404` no such thing, `410` gone (compacted) |
| `environment` | `503` |
| `external` | `502` for a backend that answered badly, `503` for one that did not answer |
| `internal` | `500`, with `saved` set to the bundle path |

The JSON carries no `docs` or `more` field because both are derived from the code
(DIAGNOSTICS.md: "docs: automatic"). The console derives them the same way the CLI does:
`more` is `zcube explain <code>` (`zbx explain` for `ZBX-`), `docs` is
`https://zigbox.github.io/<product>/errors/<code>.html`.

## Endpoints

### `GET /v1/status`

Answers even when the store is down, and never touches it, so the console can tell "server
down" from "store down".

```json
{ "server": {"version": "0.0.0", "started_at_ms": 1761350000000},
  "store": {"backend": "postgres", "ok": true, "revision": 412, "compacted_revision": 380},
  "time_ms": 1761350123456 }
```

With the store unreachable, `store` is `{"backend": "postgres", "ok": false, "diagnostic": {…}}`
and `revision` is absent. A server that guards its store (every `zcube-server`) adds, inside
`store` and beside `revision`, `remembered`: the highest `{"revision", "hash"}` it has seen (an
empty object before the first status), and, only while saving that pair fails,
`remembered_save_failed`: a `ZC-E0216` diagnostic. `time_ms` is the server's clock: the console shows ages ("3 s ago")
against it, so a skewed laptop clock does not make "just now" read "in 4 minutes".

### `GET /v1/list?prefix=&at=&limit=&continue=&reverse=`

`Store.list`, one to one. `kvs` is ascending by key unless `reverse=true`.

```json
{ "revision": 412,
  "kvs": [ { "key": "/services/hello", "value": {"v": 1, "name": "hello", "…": "…"},
             "create_revision": 12, "mod_revision": 398, "lease": 0 } ],
  "continue": null }
```

`at` reads at a revision; below the compaction point it is `410` with `ZC-E0203`, above the
current one `400` with `ZC-E0204`. `limit` is at most 500. `continue` is the last key of a
truncated page; pass it back with the first page's `at`. **`reverse` is new** (see below).

### `GET /v1/watch?prefix=&prefix=&from=&timeout=`

The long-poll watch of HANDOFF. Waits up to `timeout` milliseconds (default and maximum 25000;
`0` answers at once) for events with `mod_revision >= from`, and returns:

```json
{ "revision": 415,
  "events": [ { "type": "put",    "kv": { "key": "/observed/node1/hello-9", "value": {…}, "mod_revision": 414, "create_revision": 414, "lease": 0 } },
              { "type": "delete", "kv": { "key": "/replicas/hello/hello-3", "value": null, "mod_revision": 415, "create_revision": 0, "lease": 0 } } ] }
```

- Same guarantees as `Watch.next`: ordered, no gaps, a revision's events never split across
  responses, an idle response still advances `revision` (the bookmark). The client resumes with
  `from = revision + 1`.
- `from` at or below the compaction point: **`410`** with the **`ZC-E0203`** diagnostic. The
  client lists again and watches from the revision the list returned.
- `from` more than one past the current revision: `400` with `ZC-E0204`.
- **`prefix` may repeat** (events matching any of them, one revision order). HANDOFF specifies
  one prefix. The console follows five key ranges, and five parallel watches would mean five
  connections and five bookmarks to keep consistent. If the owner prefers one prefix, the
  console falls back to five watches, with no other change.
- The store being down is `503` with `ZC-E0201`, immediately, not after the timeout.

### `GET /v1/leases`

```json
{ "time_ms": 1761350123456,
  "leases": [ {"id": 43, "ttl_ms": 10000, "remaining_ms": 7900, "keys": ["/nodes/node3"]} ] }
```

Keepalives do not create revisions, so no watch can report them. The Nodes screen needs "TTL
remaining", so it polls this every 2 s. See the Store note below.

### `GET /v1/why/{service|replica|node}/{name}[?decision=<id>]`

`zcube why`, computed once on the server so the CLI and the console print the same words. The
chain starts at the subject's newest decision (or at `decision` if given, which the console's
history lists use) and follows each decision's `cause` (`docs/keys.md`) until it reaches a
terminal.

```json
{ "v": 1, "revision": 29,
  "subject": {"kind": "service", "name": "broken"}, "at_decision": null,
  "state": {"exists": true, "health": "failing", "desired": 1, "running": 0, "text": "service broken: 0/1 running"},
  "steps": [
    { "type": "decision", "text": "replica broken-1 failed to start on node1; it was not replaced because a new one would fail the same way",
      "decision": { "id": "…-0025", "at_ms": 1761350000123, "actor": "replica-controller", "action": "hold_failed_replica",
                    "subject": {"kind": "service", "name": "broken"}, "reason": "…", "cause": {"kind": "observed", "key": "/observed/node1/broken-1", "revision": 28} } },
    { "type": "observed", "text": "broken-1 on node1: stopped (failed to start)",
      "key": "/observed/node1/broken-1", "revision": 28, "diagnostic": { "code": "ZBX-E0501", "…": "…" } } ] }
```

- `step.type` is `decision`, or a terminal: `observed`, `desired`, `resync`, `lease_expired`
  (new, below), or `gone` when a decision in the chain has been removed by retention.
- **`state.text` and every `step.text` are the sentences the CLI prints.** The CLI renders
  `state.text`, then `← <text>` per step, and a step with a `diagnostic` as the full diagnostic
  block instead (HANDOFF's `← error[ZBX-E0501]: image not found …` form). The console may add
  structure around the text (who, when, links, the revision) but never different claims.
- `state.health` is `healthy`, `degraded`, `failing` or `gone`.
- Unknown subject with no decisions: `404`, `ZC-E0101`. A deleted subject whose decisions
  survive (24 h, keys.md) answers `200` with `state.exists: false`.

### `GET /v1/codes` and `GET /v1/explain/{code}`

The registry, for the console's code reader. `codes` is `[{code, severity, blame, summary}]`;
`explain` adds the long `explanation` text, byte for byte what `zcube explain` prints. Codes
from Zigbox's registry (`ZBX-`) are served too, since a runtime diagnostic travels inside
observed state; the server gets their text from the linked `zigbox` module.

## Writes (approved 2026-10-27)

**Status: approved by the owner on 2026-10-27**, as written below: `POST /v1/apply` with
`?dry_run=1`, and `DELETE /v1/services/{name}`, unauthenticated until auth exists. Everything above
is the read-only API, approved on 2026-10-26 and unchanged. `zcube apply` and `zcube delete`
([cli.md](cli.md)) call these two endpoints; `src/apply.zig` decides what is written (the
generation rules, the change summary) and they are implemented in the core (`src/api.zig`, bytes to
bytes like the rest) and routed by the server.

**Writes are unauthenticated until auth exists.** Anyone who can reach the server's address can
apply and delete services. `applied_by` is a name the caller chooses, recorded for the audit
trail and the `zcube why` text; it proves nothing (the command line sends `user@host`). The
console never calls either endpoint. Run the server on a loopback or otherwise private address
until auth is built.

### `POST /v1/apply[?dry_run=1]`

The body is one service as JSON; the CLI parses the `.zon` file and sends this. Unknown fields
are refused (`ZC-E0104`), so a typo cannot be silently ignored.

```json
{ "name": "hello", "image": "b3:51aa9c03", "replicas": 3,
  "command": ["sh", "-c", "while true; do sleep 1; done"],
  "env": [["KEY", "value"]], "limits": {"cpu_millis": 500, "memory_bytes": 268435456},
  "applied_by": "alex@laptop" }
```

`name`, `image`, `replicas` and `command` are required; `env`, `limits` and `applied_by` are
optional (`applied_by` defaults to `anonymous`). The rules are `apply.zig`'s: a count change alone
does not bump `generation`; a change to the image, command, env or limits does.

The answer is the decision id and the one-line summary (api.md item 5), whether or not it wrote:

```json
{ "request_id": "r-5f3a91c2-0001a4f", "dry_run": false, "action": "update", "name": "hello",
  "generation": 1, "change": "replicas 3 → 5", "revision": 431,
  "decision": "0001761350123456-0001-0007" }
```

- `action` is `create`, `update`, `none` (what was sent is what is stored; nothing written, so no
  `revision` or `decision`) or `delete`.
- **`?dry_run=1`** computes the same answer and writes nothing: `dry_run` is `true`, and `revision`
  and `decision` are absent. A dry run needs the store to read the current service.
- A write whose compare fails (someone else changed the service during the request) is read and
  planned again up to three times, then refused with `409` and the new **`ZC-E0105`**.
- Invalid input (a bad name, no command, too many replicas, a body that is not a service) is
  `400` and `ZC-E0104`. A store that is down is `503` and `ZC-E0201`, as everywhere.

### `DELETE /v1/services/{name}[?applied_by=<name>]`

Deletes the service key and records a `delete_service` decision in one transaction; the replica
controller then stops its replicas. The answer has the shape above with `"action": "delete"`.
No such service is `404` and `ZC-E0101`.

### New diagnostic codes

| Code | Blame | Summary | Raised by |
| --- | --- | --- | --- |
| `ZC-E0105` | user | the service changed while it was being applied | the write endpoints, `409` |
| `ZC-E0106` | user | the server's configuration can't be used | `zcube-server` at start-up |
| `ZC-E0107` | environment | can't listen on the server's address | `zcube-server` at start-up |
| `ZC-E0108` | environment | the server is at one of its limits | the HTTP shell, `503` (or `413` for a request that is too large) |

`ZC-E0106` to `ZC-E0108` belong to the server shell, not to the endpoints; they are listed here
because they travel in the same diagnostic shape. A request the shell refuses before the API sees
it (a body over the limit, too many connections) still answers with the error body above and an
`X-Request-Id`.

### What is not in this proposal

The agent's endpoints (registration, its watch, observed-state reports) arrive with the agent in
slice 6. Auth, scopes and the `--force`/plan-hash flow of SPEC do not exist yet.

## New diagnostic codes this needs

The console has to explain its own failures. The `01xx` range is "API and CLI". Proposed, for
the owner to number:

| Code | Blame | Summary | Raised by |
| --- | --- | --- | --- |
| `ZC-E0101` | user | no such resource | the server, for `404` |
| `ZC-E0102` | environment | can't reach zcube-server | the **console** (and the CLI), when a request fails below HTTP |
| `ZC-E0103` | environment | zcube-server sent a reply the console can't read | the **console**, for a non-JSON or malformed reply |

A diagnostic the console raises itself is marked "raised by the console" in the UI, so nobody
looks for it in server logs.

## What the console needs from the contracts

Each item is something the UI showed to be missing or awkward. **All 11 are approved by the
owner (2026-10-26)**, with the resolutions proposed here and the answers to items 10 and 11
below. `Store.list` with `reverse` and `Store.lease_list` (items 1 and 2) are built in all three
backends (C0 slice 4), and the record shapes of the other items are in `docs/keys.md`; no
controller or API handler writes them yet.

1. **[Approved]** **Newest-first reads.** "Latest decisions" and every history list want the tail of a key
   range. `Store.list` is ascending only, so the server would read every decision to show eight.
   Proposed: `reverse: bool` on `ListOptions` (additive, both backends can do it with
   `ORDER BY key DESC`). Without it, the overview needs a separate ring key
   (`/decisions-latest/`), which is worse.
2. **[Approved]** **Lease inspection.** `Lease{id, ttl_ms}` comes only from `grant` and `keepalive`. Nothing
   can read a lease's remaining time or its keys, so "lease state and TTL, last seen" (a stated
   requirement for the Nodes screen) has no source. Proposed: a read-only `lease_list()` on
   `Store`. The alternative, the server recording the time of each keepalive it forwarded, works
   for one server and breaks with two.
3. **[Approved]** **A cause for "the key was deleted by a lease".** A lost node leaves no observed record, so
   the `observed` cause kind cannot point at anything. Proposed: a fifth cause kind
   `lease_expired` with `{key, lease, ttl_ms, revision}`. The mock and `/v1/why` already use it.
4. **[Approved]** **Who applied, and from which file.** `zcube why` ends at `desired` ("an apply"); SPEC's
   audit log wants an actor and request ID, and "config in git" wants the file's commit.
   Proposed: `applied_by` and `request_id` on `/services/<name>` now, `source` (git commit, file
   digest) later. The mock writes the first two.
5. **[Approved]** **Spec history for diffs.** The previous generation's spec is gone after compaction, so
   neither a "what changed" view nor `zcube apply`'s diff of an old apply can be shown. Cheap
   option: the `apply` decision records a one-line change summary ("replicas 3 → 5").
6. **[Approved]** **Resolved requests on the replica.** Node "used" capacity is the sum of replica `limits`,
   and a replica with no limits counts as 0 although the scheduler must assume something. Put
   the scheduler's resolved `requests` (`cpu_millis`, `memory_bytes`) on the replica record.
7. **[Approved]** **`started_at_ms` on observed state**, for a replica "age" column. `reported_at_ms` moves on
   every status change, which is not the same thing.
8. **[Approved]** **Environment values are secrets in `/services/<name>`.** The API must not send them to a
   read-only token; send names only. The console masks them anyway, but that is the second line
   of defence, not the first.
9. **[Approved]** **Service-level decisions.** `zcube why service x` needs decisions whose subject is the
   service ("scale_up", "replace_replica", "hold_failed_replica"), not only per-replica ones,
   or the chain for a service starts nowhere. The mock records both, linked by `cause`.
10. **[Approved]** **`generation` and replica counts.** keys.md says `generation` rises on every spec change
    and the controller replaces replicas whose generation is behind. Read literally, scaling
    from 3 to 5 would replace the existing 3. The mock does not bump it for a count change.
    The owner should say which is intended.
11. **[Approved]** **What a failed start does.** HANDOFF says nothing about whether the controller replaces a
    replica whose `start_failed` is the user's fault (a bad digest). The mock holds it and says
    so (`hold_failed_replica`), because replacing it forever hides the cause in churn. This is a
    controller decision the UI depends on for a calm `why`.

**Owner's answers.** Item 10: a change of the replica count alone does **not** bump
`generation`. Item 11: a replica whose start failed through the user's fault (for example
`ZBX-E0501`) is **held**, with a `hold_failed_replica` decision, and not retried or replaced.

## Agent endpoints (slice 6a)

**Status: proposed in slice 6a, for the supervisor and the owner to review in the PR.** Nothing
above changes. HANDOFF says "agents watch desired state and report observed state over HTTP and
JSON, and the server never pushes to agents"; these are the endpoints that make that so. They are
implemented in the core (`src/agent_api.zig`, bytes in, bytes out, routed from `Api.route`) and
used by `zcube-agent` through `src/agent_remote.zig`. [agent.md](agent.md) says how the agent
uses them.

**Unauthenticated, and they return secrets.** `GET .../replicas` carries `env` values (the agent
must start the container with them), and the write endpoints change the store. Like `POST
/v1/apply`, they are for a loopback or private address until auth exists. A token scope for
agents is the natural first use of auth: a node's token would name the one `{node}` it may use.

### Why dedicated endpoints and not `/v1/list` and `/v1/watch`

The agent could read `/v1/list?prefix=/replicas/`, but that endpoint hides `env` values from a
read-only token (item 8), which is right for the console and wrong for the agent. A node-scoped
read also keeps the agent from having to read the whole fleet, and the node-scoped writes mean an
agent cannot write a key that is not its own: the server builds each key from the `{node}` in the
path and refuses a record that names another node.

### The shape of a conversation

The agent core (`agent.zig`) makes four kinds of store call. Each is one endpoint, so the core
runs unchanged on the far side of HTTP:

| Store call the core makes | Endpoint |
| --- | --- |
| `lease_grant(ttl)` | `POST /v1/agent/nodes/{node}/lease` |
| `lease_keepalive(id)` | `POST /v1/agent/nodes/{node}/lease/{id}/keepalive` |
| `txn` with one put of `/nodes/<node>` on a lease | `PUT /v1/agent/nodes/{node}` |
| `list(/replicas/)`, filtered to the node | `GET /v1/agent/nodes/{node}/replicas` |
| `list(/observed/<node>/)` | `GET /v1/agent/nodes/{node}/observed` |
| `txn` of puts and deletes under `/observed/<node>/` | `POST /v1/agent/nodes/{node}/observed` |
| (the wait between steps) | `GET /v1/agent/nodes/{node}/watch?from=&timeout=` |

`{node}` is a node name (a hostname label, at most 63 bytes). Errors are the diagnostics of
"Errors" above, with the same statuses; unknown fields in a body are `400` and `ZC-E0104`.

### `POST /v1/agent/nodes/{node}/lease`

Body `{"ttl_ms": 10000}`; answer `{"lease": {"id": 43, "ttl_ms": 10000}}`. A ttl outside the
store's range is `400` and `ZC-E0206`. The lease is the store's: it expires by the store's clock.
The server does not remember which node asked, so a lease is tied to the node only by the key
registered on it.

### `POST /v1/agent/nodes/{node}/lease/{id}/keepalive`

No body; the same answer. **A lease that has ended is `503` and `ZC-E0205`**, and that code is how
the agent learns it must grant a new lease and register again (`agent.zig` does exactly that). The
HTTP status is the blame's (environment), not "not found", on purpose: the agent reads the code.

### `PUT /v1/agent/nodes/{node}`

Registers the node: the server writes `/nodes/<node>` on the lease, in the record of keys.md.

```json
{ "lease": 43,
  "capacity": {"cpu_millis": 4000, "memory_bytes": 8589934592},
  "agent_version": "0.0.0", "address": "10.0.0.5:7070", "labels": [] }
```

`lease` and `capacity` are required, and both capacity numbers must be above 0. Answer
`{"revision": 431}`. A lease that is not the store's is `ZC-E0205`.

### `GET /v1/agent/nodes/{node}/replicas`

The node's desired replicas, and nothing else:

```json
{ "revision": 412,
  "kvs": [ { "key": "/replicas/hello/hello-3", "value": {"v": 1, "id": "hello-3", "…": "…"},
             "create_revision": 390, "mod_revision": 398, "lease": 0 } ] }
```

The shape is `/v1/list`'s, the `value` is the replica record of keys.md **with its `env` values**,
and `revision` is the revision the list was read at. A node has at most `agent_node_replicas_max`
(500, one page of a store list); more is `ZC-E0302`. **C0 filters `/replicas/` by the record's `node` field on the server.**
For C1 this is the place for the `/assigned/<node>/<replica>` index that keys.md proposes: the
scheduler would write it with `node`, and this handler would read that prefix instead. The
endpoint's shape does not change, which is why it is a list of replicas and not of keys.

### `GET /v1/agent/nodes/{node}/observed` and `POST ...`

`GET` answers `{"revision": R, "kvs": [...]}` for `/observed/<node>/`, the records of keys.md.
`POST` is one transaction, without compares (the agent is the only writer, keys.md):

```json
{ "puts": [ { "key": "/observed/node1/hello-3", "value": {"v": 1, "replica": "hello-3", "…": "…"} } ],
  "deletes": [ "/observed/node1/hello-2" ] }
```

Answer `{"revision": 431}`. The `value` is the observed record, **including `diagnostic`**: the
runtime's own diagnostic (`ZBX-E0501` for an image that is not in the node's store) reaches the
store as the agent built it, and `zcube why` renders it. The server refuses (`400`, `ZC-E0104`,
nothing written) a put whose record is for another node, whose key is not the observed key of its
record, a delete outside `/observed/<node>/`, a key named twice, and more than 16 operations.

### `GET /v1/agent/nodes/{node}/watch?from=&timeout=`

The long poll, the provisional transport of HANDOFF. `from` is a revision (at least 1) and
`timeout` is up to 25000 milliseconds (the default). Answer:

```json
{ "revision": 415, "changed": true }
```

`changed` is true if any key under the watched prefix (C0: `/replicas/`; C1: the node's
`/assigned/` prefix) was written or deleted at a revision `>= from`. If nothing has changed the
server holds the reply up to `timeout`, as for `GET /v1/watch`, and answers with `changed: false`
and the bookmark when the time is up. **The reply carries no events**, because the agent
reconciles by level: it reads the list again and lets the core decide, so a lost or compacted
event cannot matter. The agent lists, remembers the list's `revision`, and watches from
`revision + 1`.

`from` more than one past the store's revision is `400` and `ZC-E0204`; `from` below the
compaction point is `410` and `ZC-E0203`, and the agent treats that as "changed" and lists again.

### What the agent does with them

1. Grant a lease, `PUT` its registration, and `POST` a keepalive every third of the ttl
   (`agent.zig`'s heartbeat). A `ZC-E0205` from a keepalive means the lease is gone: grant,
   register again, and **keep the workloads** (stopping them is C1's acceptance criterion).
2. Each step: `GET replicas`, `GET observed`, drive the runtime, `POST observed` with what
   changed.
3. Between steps: `GET watch` for up to a quarter of a second, and look at the local runtime.
   A server that cannot be reached is `ZC-E0503` on the agent; it waits, backs off and retries,
   and the containers, which run under supervisors of their own, are untouched.

### New diagnostic codes

All in the agent's range, `05xx`. The first two are raised by the agent about the server; the
rest are about the agent's own host.

| Code | Blame | Summary | Raised by |
| --- | --- | --- | --- |
| `ZC-E0503` | environment | the agent can't reach zcube-server | the agent's HTTP client |
| `ZC-E0504` | external | zcube-server refused the agent's request | the agent, for a reply it cannot use |
| `ZC-E0505` | user | the agent's configuration can't be used | the agent at start-up |
| `ZC-E0506` | environment | the agent's state directory can't be used | the agent at start-up, `FakeRuntime` |
| `ZC-E0507` | environment | the agent can't start a container's supervisor | `FakeRuntime` |
| `ZC-E0508` | user | the container's command can't be run | the supervisor, as `start_failed` |
| `ZC-E0509` | environment | the container's supervisor is gone | `FakeRuntime`, as `lost` |
| `ZC-W0501` | environment | the agent's lease ended and it registered again | the agent, a warning |
