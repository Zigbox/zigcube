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

While the store answers, `findings` (C1 slice 4) lists the allocation auditor's open findings,
one per node whose allocation record disagrees with its assignments (`/audit/allocations/<node>`,
[keys.md](keys.md)): `[{"node", "recorded", "reconstructed", "revision", "decision"}]`, with each
tally as `{"allocated": {"cpu_millis", "memory_bytes"}, "count"}` and `decision` the
`allocation_mismatch` decision that opened it. An empty array is a healthy cluster; a listing that
fails leaves the member out.

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

`zcube-agent fetch --server` uses this read, unchanged, for peer discovery: one call with
`prefix=/node-store/` and `limit=65` (agent.md, "The chunk store, the peer server and `fetch`").
It adds no endpoint.

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
- **A watch that is behind the head answers at once**, whatever it holds: when `from` is at or
  below the head, the reply carries what the server read, even no events (a `prefix` that matches
  none of the first 64 batches of 256 events), with `revision` set to the bookmark it reached; it
  is held only when nothing is left to read up to the head. Resume with `from = revision + 1`.
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
      "key": "/observed/node1/broken-1", "revision": 28, "diagnostic": { "code": "ZBX-E0410", "…": "…" } } ] }
```

- `step.type` is `decision`, or a terminal: `observed`, `desired`, `resync`, `lease_expired`
  (new, below), or `gone` when a decision in the chain has been removed by retention. A `why node`
  chain may end in one more step of type `note` (C1 slice 7): a statement of the scheduler's rule,
  not a reading of the store. A client that does not know a step type prints its `text`.
- `summaries` (additive) is `[{action, cause, count, first_at_ms, last_at_ms}]`, the subject's
  `/decision-summaries` counts. A summary is a projection, never a step. The CLI prints one line
  each after the chain: `replace_replica (observed): 142 times since 2025-10-24 23:13:20Z`.
- `why node`'s `state.text` names the judgement and the load:
  `node node3: ready (tenure 22), lease 9 with 0 replicas assigned, 0m of 4000m CPU and 0B of
  8.0Gi memory in use`; a node with no `/node-status` is `registered, not yet judged`, one whose
  status is for an earlier tenure says so, and one that is not registered says `not registered`
  and, if a status remains, `last judged <state> (tenure N)`. The `note` step is added when the
  node is `ready` for its current tenure and holds fewer replicas than another registered node:
  replicas already running elsewhere are not moved back, because the scheduler does not rebalance.
- **`state.text` and every `step.text` are the sentences the CLI prints.** The CLI renders
  `state.text`, then `← <text>` per step, and a step with a `diagnostic` as the full diagnostic
  block instead (HANDOFF's `← error[ZBX-E0410]: no tree with that digest …` form). The console may add
  structure around the text (who, when, links, the revision) but never different claims.
- `completeness` (C1 slice 7, authority.md §5) says whether the chain reaches its cause:
  `{"verdict": "complete"}`, or `{"verdict": "truncated", "at": "<decision id or key>", "reason": R}`
  with `R` one of `retention` (a decision was removed: decisions are kept 200 per subject, 7 days, or 24 hours once the subject is gone), `subject_deleted`
  (the same, and the subject no longer exists) or `compacted` (a key the chain cites has changed since, the store no longer keeps its value at the cited revision, and no decision kept evidence of it; a cited key that never changed is read now and is complete). A `gone` step carries the same `reason`, and for `compacted`
  the `key`. The current value of a compacted key is never shown as the reason for it. The field is
  always present (an empty chain is `complete`); a client reading an older server may find it absent. Every actor that cites a key keeps
  its evidence: the scheduler, the node controller, the auditor, `apply`, `delete_service` and the
  replica controller write `cause_evidence`, so a terminal past compaction is `complete` and says
  the evidence, and `truncated`/`compacted` only for a decision written without any.
- `state.health` is `healthy`, `degraded`, `failing` or `gone`.
- Unknown subject with no decisions: `404`, `ZC-E0101`. A deleted subject whose decisions
  survive (24 h, keys.md) answers `200` with `state.exists: false`.

### `GET /v1/stats/pull[?node=<name>][&limit=<n>]` (C2 slice 7)

What pulls moved, by source: the `/pulls/` records of keys.md, newest `finished_at_ms` first.

```json
{ "pulls": [ { "v": 1, "node": "node1", "tree": "b3:51aa9c03…", "registry_bytes": 1048576,
  "peer_bytes": [{"peer": "node2", "bytes": 2097152}], "cached_bytes": 0,
  "started_at_ms": 1700000000000, "finished_at_ms": 1700000004000, "bad_peers": [] } ],
  "skipped": 0, "matched": 1, "truncated": false, "revision": 512 }
```

`matched` is how many records were read and kept (those counted in `skipped` are not in it)
before `limit` cut the list, and `truncated` is `true` when the server stopped reading at
`pulls_read_max` (500) records, which it reads in key order (by node), or when its page budget ran out first with fewer rows read (`truncated` can mean "page budget exhausted"): the answer is then part
of the picture, never a failure (it was `ZC-E0302` before). Both are additive members of
version 1. `node` limits the answer to one node; `limit` defaults to 50 and is at most 500
(above it, or 0, is `400` `ZC-E0104`, as is a `node` that is not a node name). The read is
tolerant: a record that is malformed, newer than the server's reader, or with a peer name that is
not a node name counts in `skipped` and is left out. Reads
need no auth beyond the server's own.

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
  "source": "registry.example/hello@sha256:<64 hex digits>",
  "applied_by": "alex@laptop" }
```

`name`, `image`, `replicas` and `command` are required; `env`, `limits`, `source` and `applied_by`
are optional (`applied_by` defaults to `anonymous`, `source` to empty). The rules are
`apply.zig`'s: a count change alone does not bump `generation`; a change to the image, source,
command, env or limits does. `source` (C2 slice 2) is the OCI reference the image is pulled from
when the node does not have it. It is empty, or at most 1024 bytes with no whitespace or control
character, ending in `@sha256:` and 64 lowercase hex digits (a tag can move, so a pin is
required); anything else is `ZC-E0104` naming the rule that failed. It is a string (any other
type is `ZC-E0104`), it is not a secret, and it appears as `source` on `/services/<name>` and
`/replicas/<service>/<id>` in the read endpoints, empty when none was given. The supervisor parses
it with Zigbox's `parse_reference`, which may refuse what apply took. `env` holds at
most 16 variables (Zigbox's `run_env_count_max`; it was 64 before C2 slice 1, which tightened it so
a service the real runtime would refuse is refused at apply).

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
- Invalid input (a bad name, no command, too many replicas, container `limits` outside the
  runtime's bounds, a body that is not a service) is `400` and `ZC-E0104`. The bounds are a job's:
  `cpu_millis` 10 to 1,024,000 and `memory_bytes` 4 MiB to 2^40, and the cause names
  `limits.<member>`. Limits the stored service already has are not re-checked, so applying the same
  file again is `none`, not a refusal (docs/decisions/2026-11-08-service-apply-limits.md). A store that is down is `503` and `ZC-E0201`, as everywhere.

### `DELETE /v1/services/{name}[?applied_by=<name>]`

Deletes the service key and records a `delete_service` decision in one transaction; the replica
controller then stops its replicas. The answer has the shape above with `"action": "delete"`.
No such service is `404` and `ZC-E0101`.

### `GET /v1/check/allocations` and `POST /v1/repair/allocations/{node}[?confirm=true]` (C1 slice 4)

The allocation accounting, for `zcube check allocations` and `zcube repair allocations`
([cli.md](cli.md)). `src/allocations.zig` rebuilds every node's tally from its assignments at one
revision; both endpoints run it in the request.

The check writes nothing:

```json
{ "revision": 431,
  "nodes": [{"node": "node1",
             "recorded": {"allocated": {"cpu_millis": 300, "memory_bytes": 3072}, "count": 3},
             "reconstructed": {"allocated": {"cpu_millis": 200, "memory_bytes": 2048}, "count": 2},
             "consistent": false,
             "finding": {"decision": "0001761350123456-0003-0001", "revision": 428}}],
  "inconsistent": 1 }
```

A node is listed when it holds an assignment or has an allocation record. `recorded` is `null`
for a node without a record; `finding` is the auditor's open finding on the node, or `null`.

The repair rewrites one node's record with the rebuilt total, in one transaction that compares
the record and the finding at the revision it rebuilt from, and records a `repair_allocation` decision
(actor `scheduler`) that cites the finding. The auditor clears the finding on its next pass.

- The node has no open finding: `409` and **`ZC-E0402`**. Nothing is written.
- Without `?confirm=true`: `400` and **`ZC-E0401`**, whose cause says what it would write.
- The accounting moved during every attempt (three, as for apply): `409` and **`ZC-E0403`**.
- Done: `200` and the same shape as an apply, with what was written:

```json
{ "request_id": "r-5f3a91c2-0001a4f", "node": "node1", "action": "repair_allocation",
  "recorded": {"allocated": {"cpu_millis": 300, "memory_bytes": 3072}, "count": 3},
  "reconstructed": {"allocated": {"cpu_millis": 200, "memory_bytes": 2048}, "count": 2},
  "revision": 432, "decision": "0001761350123999-0002-0001" }
```

A `POST` with neither `Content-Length` nor `Transfer-Encoding` has no body (RFC 9112 6.3), which is
how `zcube repair` sends one.

### New diagnostic codes

| Code | Blame | Summary | Raised by |
| --- | --- | --- | --- |
| `ZC-E0401` | user | a repair needs confirming | `POST /v1/repair/...` without `confirm`, `400` |
| `ZC-E0402` | user | the node has no open allocation finding | the repair, `409` |
| `ZC-E0403` | user | the node's accounting changed during the repair | the repair, `409` |
| `ZC-E0404` | user | a node's accounting disagrees with its assignments | `zcube check allocations` (the CLI, exit 1) |
| `ZC-B0003` | bug | allocation accounting disagrees with assignments | the allocation auditor, in its finding's decision |
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

## Jobs (B1 slice 2)

`src/job_api.zig` decides, `src/api.zig` routes. Like the writes above they are unauthenticated until
auth exists, and so are the secrets in them: **a job's `env` values and `input` are readable by
anyone who can reach the server's address** (the read-only `GET /v1/list` redacts them; the writing
token does not, and the agent's endpoints serve them to the node). Do not put a secret in a job on a
shared network.

### `POST /v1/jobs`

The body is the job as JSON: `name`, `image`, `command`, `deadline_ms`, `submit_by_ms` (required),
`source`, `env` (`[["NAME","value"]]`), `limits`, `labels`, `grace_ms`, `input` (UTF-8 text, at most
64 KiB decoded) with `input_env` (the variable it is given in), `applied_by`. `retries` above 0,
`relay` and `placement` are refused by name (ZC-E0130, not built yet); an unknown field is `400`
ZC-E0104. Answers `201` for a new job, `200` when a job of that name with the same spec already
exists (spec fields only: `submit_by_ms` and `applied_by` are not compared), `409` ZC-E0131 when
it exists with another spec, `429` ZC-E0132 at `jobs_max` jobs in flight or `job_admitted_window_max`
creations in `job_admission_window_h` hours, `410` ZC-E0134 when `submit_by_ms` has passed,
`400` ZC-E0104 for a body that does not parse, with a cause that says which way (a missing field, an unknown
one, a value of the wrong type or a number out of range for its field, JSON that ends too soon, not JSON),
`400` ZC-E0130 naming the field for everything else, including a job whose run record would take
more than `job_run_bytes_max` (16 KiB) once its `command`, `env`, `labels`, `source` and `image`
are escaped (a control character takes six bytes in JSON).

- **Idempotency.** `env` and `labels` are compared as maps, in any order; a key given twice in either
  is `400` ZC-E0130. The expiry (`submit_by_ms`) is checked after the lookup: a retry of a job that
  exists answers `200` with it even when `submit_by_ms` has passed, and `410` ZC-E0134 is for a
  job that does not exist. The lookup also comes before the bounds of `limits` and the repeated-key
  check: a retry of a job stored before those existed (#178), equal to the stored spec, answers
  `200` (`same`) and not `400` ZC-E0130; a new job, or a different spec, is refused as above.
- **`limits`** are bounded like the runtime's: `cpu_millis` 10 to 1,024,000, `memory_bytes` 4 MiB to
  2^40, `pids` 1 to 4,194,304; outside them is ZC-E0130 naming `limits.<member>`.
- **The admission window** counts creations in hourly buckets, so it covers the last
  `job_admission_window_h` hours and the current, partial one: a creation is forgotten 72 to 73 hours
  later. A bucket ahead of the clock (the clock was stepped back) is dropped, not folded into the
  present.
- A job record cannot reach `store_value_bytes_max`: a run record over `job_run_bytes_max` is
  already `400` ZC-E0130 (`check_run_size`), and the Job record holds the same fields
  (docs/decisions/2026-11-08-zc-e0207-cut.md). ZC-E0207 stays `503` for other records (service specs).

**This is the one route whose body may exceed 64 KiB.** A 64 KiB input of control characters is
about 384 KiB of JSON, so `POST /v1/jobs` takes a body of up to `job_request_bytes_max`
(`6 * job_input_bytes_max + 16 KiB`, 409,600 bytes); every other route keeps `http_body_bytes_max`
(64 KiB). A longer body is `413` ZC-E0108 and its cause names the limit of this route. The limit is
decided on the decoded input, not the wire: an input within 64 KiB, with the rest of the job
within 16 KiB as sent, is always stored. A body must arrive within `http_idle_timeout_ms` (10 s) of
the request's start, so the slowest client the largest body allows is `job_request_bytes_max` over
10 s, about 40 KB/s (40,960 bytes a second); a slower client, or one that stalls part way, is
disconnected with no code. (`docs/decisions/2026-11-06-b1-slice-2-review-followups.md`.) The
`state` of a `200` (same job) and of every cancel reply is the job's state now, `pending` only while
it has no status.

### `GET /v1/jobs/{name}`, `GET /v1/jobs`

The first answers `{revision, job, state, status}`: `job` is the spec with `env_names` (names, never
values), `input_digest` and `input_bytes` (never the input), `cancel_requested`. `404` ZC-E0133 for
a job that does not exist. The second takes `state=` (a job state, or `ended` for every terminal
state), `label=key[=value]`, `limit=` (1 to 500, default 50), `at=` and `continue=`, and answers
`{revision, jobs, continue}` (a row of a job that was placed carries the `epoch` of its run, an unplaced ending carries none; a row of an ended job carries `ended_at_ms`, the time its status recorded the ending, set once and never changed, absent while the job has not ended); a filter keeps a subset of each store page, so a page may hold fewer
than `limit` rows and `continue` may still be set.

### `GET /v1/jobs/watch`

`/v1/watch` over `/job-status/`, the values decoded to job statuses: `from=` (required, at least
1: the first revision wanted), `timeout=` (at most 25000 ms) and `label=key[=value]`. It answers
`{revision, events}`; each event is `{type: put|delete, name, revision, status}` (`status` is
absent on a delete). `revision` is the bookmark: pass `revision + 1` as the next `from`, also
when `events` is empty (a batch whose events all fell to `label` still advances it). A `label`
keeps the events of jobs that match it at the head (the job now holding the name, a reused one included) and drops deletes. `410` ZC-E0203 when `from`
is below the compaction point, `400` ZC-E0204 when it is beyond the head. The client's contract:
watch; on a 410, list `state=ended`, deduplicate (a row carries the `epoch` of the run it ended
under, none for an unplaced ending, and `ended_at_ms`; an event's `status` carries the same
members) and watch again from the list's `revision + 1`. Every ending is then seen at least once;
handle it by its key to see it exactly once. The key is `(name, epoch)` when `epoch` is present and
non-zero (a store revision, unique per placed ending, so it works against any server) and
`(name, ended_at_ms)` only for an unplaced ending, where it is the only thing that tells two
endings of a name reused after retention apart. An absent `epoch` counts as none, an absent
`ended_at_ms` as 0 (an older server's row; it only matters for an unplaced ending)
(`docs/decisions/2026-11-06-job-dedupe-key-adopted.md`). The name `watch`
is reserved: `POST /v1/jobs` refuses it with ZC-E0130.
Like `/v1/watch`, a poll that is behind the head answers at once.
A job's `why` chain can now end in a `hold_unreadable_job` decision (B2 slice 2): the job controller skipped a
record, run or status that did not decode, citing ZC-E0301 or ZC-E0303.

### `POST /v1/jobs/{name}/cancel`

Body empty or `{"applied_by": "..."}`. Records `cancel_requested` and answers `202`; the job
controller stops the run. A second cancel answers `202` and writes nothing; a job that has ended
answers `200` with its `end`. `404` ZC-E0133 if there is no such job. `GET /v1/why/job/{name}` is
the job's chain of decisions.

| Code | Blame | Summary | Status |
| --- | --- | --- | --- |
| `ZC-E0130` | user | the job can't be accepted (its cause names the field) | `400` |
| `ZC-E0131` | user | a job with this name exists with another spec | `409` |
| `ZC-E0132` | user | too many jobs | `429` |
| `ZC-E0133` | user | no such job | `404` |
| `ZC-E0134` | user | `submit_by_ms` has passed | `410` |

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
   Proposed: `applied_by` and `request_id` on `/services/<name>` now, `provenance` (git commit, file
   digest) later (named `source` before C2 slice 2, which took that name for the OCI
   reference). The mock writes the first two.
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
`ZBX-E0410`) is **held**, with a `hold_failed_replica` decision, and not retried or replaced.

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
| `txn` with one put of `/node-store/<node>` on the same lease (C2 slice 5) | `PUT /v1/agent/nodes/{node}/store` |
| `txn` with one put of `/pulls/<node>/<tree>` (C2 slice 7) | `POST /v1/agent/nodes/{node}/pulls` |
| `list(/replicas/)`, filtered to the node | `GET /v1/agent/nodes/{node}/replicas` |
| `list(/observed/<node>/)` | `GET /v1/agent/nodes/{node}/observed` |
| `txn` of puts and deletes under `/observed/<node>/` | `POST /v1/agent/nodes/{node}/observed` |
| `list(/job-runs/)`, filtered to the node's assignments (B1 slice 4) | `GET /v1/agent/nodes/{node}/runs` |
| `get(/job-input/<name>)` | `GET /v1/agent/nodes/{node}/runs/{name}/input` |
| `list(/job-observed/<node>/)`; `txn` with one put there | `GET` / `POST /v1/agent/nodes/{node}/job-observed` |
| (the wait between steps) | `GET /v1/agent/nodes/{node}/watch?from=&timeout=` |

`{node}` is a node name (a hostname label, at most 63 bytes). Errors are the diagnostics of
"Errors" above, with the same statuses; unknown fields in a body are `400` and `ZC-E0104`.

### `POST /v1/agent/nodes/{node}/lease`

Body `{"ttl_ms": 10000}`; answer `{"lease": {"id": 43, "ttl_ms": 10000}}`. The server grants its
own configured ttl (`--lease-ttl-ms`, default 10 s, refused with `ZC-E0121` if an agent could not
fence in time under it) and ignores the body's, so the body's ttl is never checked or refused;
the agent adopts the ttl in the answer, and refuses one it could not fence under with
`ZC-E0504` (it then registers nothing). The lease is the store's: it expires by the store's clock.
The server does not remember which node asked, so a lease is tied to the node only by the key
registered on it.

### `POST /v1/agent/nodes/{node}/credential` (C2 slice 6a)

The join of docs/peer.md. Body `{"node_key": "<64 hex digits>", "lease": N}` (the node's Ed25519 public key and the
lease its record is registered under; 
at most `peer_join_request_bytes_max` bytes, no unknown fields). The server's CA signs a
credential binding that key to `{node}` for `peer_credential_ttl_ms` from its wall clock, and
answers

```json
{ "credential": "<hex, 185 bytes>", "ca_public": "<64 hex digits>",
  "not_before_ms": 1767225600000, "not_after_ms": 1767312000000 }
```

The agent calls it again at half the credential's life. Refusals: `400` for a key that is not 64
hex digits or not a point on the curve, or a node name that is not a node name; `ZC-E0807` for a
node on the server's `revoked` file (read at start); `404` where the server has no CA (the
simulation's `Api`); `400` for a `lease` of 0; `ZC-E0205` for a node whose record is not on that
lease (a store read of `/nodes/{node}`). The reply carries **no chain pair**: the call writes
no store key, and the CA is not a store writer (authority.md, section 2). Like every agent endpoint it is
unauthenticated until the API has auth (docs/peer.md, "Trust model").

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

### `PUT /v1/agent/nodes/{node}/store` (C2 slice 5)

Writes the node's image summary, `/node-store/<node>` of keys.md, bound to the node's lease. The body
is the record itself plus the lease:

```json
{ "lease": 43, "v": 1, "node": "node1", "trees": [ { "tree": "b3:51aa9c03", "bytes": 52428800,
  "chunks": 800, "sample": "<hex>" } ], "filter": "<hex>", "filter_chunks": 800, "omitted": 0 }
```

Answer `{"revision": 433}`. The write is one transaction under the node's tenure compare, as an
observed write is. Refusals: `v` other than 1, `node` other than `{node}`, a lease of 0, a lease
that is not the one `/nodes/<node>` was registered on, or more than `summary_trees_max` (32) trees
are `400` and `ZC-E0104`; a tenure that has ended (no registration, or one newer than the agent's)
is `503` and `ZC-E0510`. Fields the server does not know are **ignored** (the record is advisory
and may grow). The endpoint has its own body cap, `summary_request_bytes_max` (about 217 KiB: the
filter and the samples are hex, so the largest record is twice its binary size, plus JSON
overhead); every other agent body stays at 64 KiB. A stored value over `store_value_bytes_max`
(256 KiB) is `400`. A server older than C2 has no such route: the agent gets a `404` (`ZC-E0504`),
notes it once on stderr and goes on, because replica work never waits for a summary.

### `POST /v1/agent/nodes/{node}/pulls` (C2 slice 7)

Writes one pull record, `/pulls/<node>/<tree>` of keys.md. Not lease-bound: statistics outlive
the node. The body is the agent's tenure (the revision of its registration, as for an observed
write) and the record:

```json
{ "tenure": 430,
  "pull": { "v": 1, "node": "node1", "tree": "b3:51aa9c03…", "registry_bytes": 1048576,
  "peer_bytes": [], "cached_bytes": 0, "started_at_ms": 1, "finished_at_ms": 2, "bad_peers": [] } }
```

Answer `{"revision": 434, "chain": …}`. One transaction under the node's tenure compare. Refusals:
`v` other than 1, `node` other than `{node}`, an empty `tree`, a peer name (in `peer_bytes` or
`bad_peers`) that is not a node name, more than `pull_peers_max`
peers, a record that encodes past `pull_record_bytes_max` (4 KiB), or a body over
`pull_request_bytes_max` (8 KiB) are `400` `ZC-E0104`; a tenure that has ended is
`503` `ZC-E0510`. A server older than C2 slice 7 answers `404` (`ZC-E0504`): the agent drops the
file without saying so, and goes on (statistics are never worth holding replica work back; a
server that cannot be reached leaves the file for the next step).

### `GET /v1/agent/nodes/{node}/replicas`

The node's desired replicas, and nothing else:

```json
{ "revision": 412,
  "kvs": [ { "key": "/replicas/hello/hello-3", "value": {"v": 2, "id": "hello-3", "…": "…"},
             "create_revision": 390, "mod_revision": 398, "lease": 0 } ] }
```

The shape is `/v1/list`'s, the `value` is the replica record of keys.md **with its `env` values**,
and `revision` is the revision the list was read at. A node has at most `agent_node_replicas_max`
(500, one page of a store list); more is `ZC-E0302`. **From C1 slice 3 the server serves the
replicas named under `/assigned/<node>/`** (the scheduler's), read at the revision of the replica
list; an assignment whose replica is gone is not served, so the agent stops that container. (C0
filtered `/replicas/` by the record's `node` field, which a `"v": 2` replica no longer has.) The
endpoint's shape did not change, which is why it is a list of replicas and not of keys.

**A C0 agent cannot run against a C1 server.** The records are `"v": 2`, and a C0 agent refuses
a value whose version is newer than it knows with `ZC-E0303`, naming the key and both versions
(keys.md, "Versions"). Upgrade the agents with the server.

### `GET /v1/agent/nodes/{node}/assigned`

The node's assignments, as stored: `{"revision": R, "kvs": [...]}` in `/v1/list`'s shape for
`/assigned/<node>/`, each `value` the assignment record of keys.md:

```json
{ "revision": 415,
  "kvs": [ { "key": "/assigned/node1/hello-3",
             "value": {"v": 1, "replica": "hello-3", "service": "hello",
                       "requests": {"cpu_millis": 250, "memory_bytes": 134217728},
                       "reason": "node1 is the only node, and it fits 250m CPU and 128 MiB"},
             "create_revision": 398, "mod_revision": 398, "lease": 0 } ] }
```

`GET` only; no query but `known` ("The chain pair" below), and the answer carries `chain`
like every other agent endpoint. At most `agent_node_replicas_max` (500) assignments; more is `ZC-E0302`.
The key's `mod_revision` is the replica's placement epoch (keys.md).

### `GET /v1/agent/nodes/{node}/observed` and `POST ...`

`GET` answers `{"revision": R, "kvs": [...]}` for `/observed/<node>/`, the records of keys.md.
`POST` is one transaction, without compares (the agent is the only writer, keys.md):

```json
{ "tenure": 412,
  "puts": [ { "key": "/observed/node1/hello-3", "value": {"v": 1, "replica": "hello-3", "…": "…"} } ],
  "deletes": [ "/observed/node1/hello-2" ] }
```

`tenure` is the revision of the agent's `/nodes/<node>` registration (0 or missing is `400`). The
transaction compares the registration's `mod_revision` with it: a node whose registration was
replaced or deleted is refused with `503` and `ZC-E0510` and nothing is written (I2).

Answer `{"revision": 431}`. The `value` is the observed record, **including `diagnostic`**: the
runtime's own diagnostic (`ZBX-E0410` for an image that is not in the node's store) reaches the
store as the agent built it, and `zcube why` renders it. The server refuses (`400`, `ZC-E0104`,
nothing written) a put whose record is for another node, whose key is not the observed key of its
record, a delete outside `/observed/<node>/`, a key named twice, and more than 16 operations.

### `GET /v1/agent/nodes/{node}/runs`, `GET .../runs/{name}/input`, `GET` and `POST .../job-observed` (B1 slice 4)

`runs` lists the job runs (`/job-runs/`) assigned to the node, as `{"revision", "kvs"}` like
`replicas`; more than `agent_node_runs_max` is `ZC-E0302`. The server reads the node's own
assignments and then each run by its key, never every retained run of the cluster. `runs/{name}/input` answers the job's `JobInput` (keys.md) only to the node that holds the run's
assignment and only after it has claimed the run (its `/job-observed/<node>/<name>` exists), and
`ZC-E0133` otherwise, so an input never reaches a node that was not placed the run or that lost the
claim. The agent checks `sha256:<hex>` over the decoded bytes against the job's `input_digest`.

`job-observed` `GET` lists `/job-observed/<node>/` one page at a time: at most
`store_list_limit_max` records, with `"more": true` when others follow, and
`?after=<run name>&at=<revision>` resumes after that run at the revision the first page answered.
A node can hold up to `job_admitted_window_max` (the bound on retained runs), which is never one
reply. Upgrade the server before the agents: an older agent reads only the first page, and a newer
agent against an older server is refused its second page. `POST` is one put of `/job-observed/<node>/<name>`:

```json
{ "tenure": 412, "run_revision": 87, "observed_revision": 0,
  "value": {"v": 1, "run": "batch-job", "status": "claimed"} }
```

`observed_revision` (additive, default 0) is for a claim only: the `mod_revision` of the node's
leftover observation of an earlier job of the same name, which the claim then replaces instead of
requiring the observation to be absent. The server refuses (`400`) a value that names an
observation made under an assignment newer than the run's creation.

The server compares the tenure, and for a claim (`status` `claimed`) also the run's `mod_revision`
(`run_revision`), the assignment's `mod_revision` (the epoch in the record) and the absence of the
observation. A claim whose compares fail while the tenure holds answers `200 {"applied": false}`
and writes nothing: the run moved or was claimed before. A replaced tenure is `503` `ZC-E0510`.

A `running` or `stopped` report also compares the assignment it names (`value.assignment`, which
must not be 0): `/assigned/<node>/<run>` must still be at that revision. A report of a run that was
retired (its assignment released) or superseded (placed again, or the name reused) answers
`200 {"applied": false}` and writes nothing, so the store holds no observation the job controller
would ignore (B2). The agent reports a run only under the assignment it read in the same pass, drops a refused
report and ends the run on its node. An older
server stores it; the answer shape is unchanged. An older agent fences on `applied: false`, so
upgrade agents before the server.

### `GET /v1/agent/nodes/{node}/watch?from=&timeout=`

The long poll, the provisional transport of HANDOFF. `from` is a revision (at least 1) and
`timeout` is up to 25000 milliseconds (the default). Answer:

```json
{ "revision": 415, "changed": true }
```

`changed` is true if any key under `/assigned/<node>/` was written or deleted at a revision `>= from`
(C1 slice 7; before it the watch also woke on every `/replicas/` change and on any node's
assignment, so every agent woke for every placement). The agent lists its assignments and joins each
replica record, and every change it must act on is a change of its own assignments: a replica
record is written once and removed, never edited, and the scheduler deletes the assignment of a
replica that is gone. With nothing changed, `revision` is the scan's bookmark, so watching from
`revision + 1` skips no change. If nothing has changed the
server holds the reply up to `timeout`, as for `GET /v1/watch`, and answers with `changed: false`
and the bookmark when the time is up. **The reply carries no events**, because the agent
reconciles by level: it reads the list again and lets the core decide, so a lost or compacted
event cannot matter. The agent lists, remembers the list's `revision`, and watches from
`revision + 1`.

`from` more than one past the store's revision is `400` and `ZC-E0204`; `from` below the
compaction point is `410` and `ZC-E0203`, and the agent treats that as "changed" and lists again.

### The chain pair (C1 slice 10b)

Every `200` answer of these endpoints carries
`"chain": {"revision": R, "hash": "<64 hex>", "verified": V, "ca_key_id": "<16 hex>"}`
(`ca_key_id`, C2 slice 6a: the first 8 bytes of SHA-256 of the cluster CA's public key, when the
server has a CA; an agent whose credential names another CA joins again): for a write (registration, report),
the revision and hash of the transaction itself; otherwise the store's `status` taken after the
endpoint did its work (for the watch, the head it answered at), so it is at least as new as
anything in the answer. `verified` is `false` when the server keeps no pair for its store across
restarts (a memory store, which starts empty each time) and so does not enforce the
never-backwards rule; the agent then neither refuses such an answer nor keeps a pair, and says so
once. An answer without `verified` is read as `true`. Every endpoint takes `known=K`, the
revision the agent remembers (no other query parameter, except the watch's `from` and `timeout`).
When `K <= R`, the pair adds `"known_hash"`: the store's hash at `K` (`hash` itself when
`K == R`). It is left out when the store
has no hash there (`K` below the chain's start). A refusal carries no pair.

The agent remembers the highest pair it was given, in `<state dir>/remembered`, and refuses an
answer with a lower `revision`, a `known_hash` that differs from the remembered hash or is
missing, or the same revision with a different `hash`: `ZC-E0215`, as the server raises for its
store, and it acts on nothing in that answer. An answer without `chain` is `ZC-E0504` (the
server is older than the agent: upgrade the server first). The way out is the server's
`zcube store accept-rollback --confirm`, then `rm <state dir>/remembered` and an agent restart.

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
| `ZC-E0121` | user | the lease ttl is one an agent cannot fence in time | `zcube-server` at start |
| `ZC-E0510` | environment | an observed write under a tenure that has ended | the agent endpoint |
| `ZC-E0507` | environment | the agent can't start a container's supervisor | `FakeRuntime` |
| `ZC-E0508` | user | the container's command can't be run | the supervisor, as `start_failed` |
| `ZC-E0509` | environment | the container's supervisor is gone | `FakeRuntime`, as `lost` |
| `ZC-W0501` | environment | the agent's lease ended and it registered again | the agent, a warning |
| `ZC-E0806` | user | a peer key or trust file can't be used | `zcube-server` and the agent at start |
| `ZC-E0807` | user | the node was removed from the cluster and is refused a credential | the credential endpoint |
| `ZC-E0809` | external | a certificate is malformed or outside the bounds (the field named) | the X.509 parser, for a peer's certificate |
| `ZC-E0810` | external | a certificate is not signed by the pinned anchor | certificate verification |
| `ZC-E0811` | external | a certificate is expired or not yet valid (both times shown) | certificate verification |
| `ZC-E0812` | external | a certificate names another peer than the one asked for (both named) | certificate verification |
| `ZC-E0817` | user | an identity could not be issued | the CA, when it issues a certificate |
| `ZC-E0819` | external | a certificate was issued for another role (CA, server, workload) | certificate verification |
