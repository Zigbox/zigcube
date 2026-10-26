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
| Methods | The console uses `GET` only. Writes (`apply`) are CLI-only for now. |
| Bodies | `application/json`, UTF-8. Values are the JSON records of [keys.md](keys.md), unchanged. |
| Request ID | The server assigns one to every request and returns it in the `X-Request-Id` response header, on success and failure. A client may send its own `X-Request-Id` (`[A-Za-z0-9-]`, 8 to 64 bytes); the server then uses it. The CLI prints it with `--verbose`; bundles include it. |
| Auth | Out of scope here. SPEC says tokens are scoped; the console needs a read-only scope. A missing or insufficient token must be a diagnostic like any other. |
| Versioning | The path carries the major version. Additive fields are not a new version, so clients ignore unknown fields. |

### Errors

A failed request has a non-2xx status and this body:

```json
{
  "request_id": "r-0001a4f",
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
and `revision` is absent. `time_ms` is the server's clock: the console shows ages ("3 s ago")
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
      "key": "/observed/node1/broken-1", "revision": 28, "diagnostic": { "code": "ZBX-E0410", "…": "…" } } ] }
```

- `step.type` is `decision`, or a terminal: `observed`, `desired`, `resync`, `lease_expired`
  (new, below), or `gone` when a decision in the chain has been removed by retention.
- **`state.text` and every `step.text` are the sentences the CLI prints.** The CLI renders
  `state.text`, then `← <text>` per step, and a step with a `diagnostic` as the full diagnostic
  block instead (HANDOFF's `← error[ZBX-E0410]: no tree with that digest …` form). The console may add
  structure around the text (who, when, links, the revision) but never different claims.
- `state.health` is `healthy`, `degraded`, `failing` or `gone`.
- Unknown subject with no decisions: `404`, `ZC-E0101`. A deleted subject whose decisions
  survive (24 h, keys.md) answers `200` with `state.exists: false`.

### `GET /v1/codes` and `GET /v1/explain/{code}`

The registry, for the console's code reader. `codes` is `[{code, severity, blame, summary}]`;
`explain` adds the long `explanation` text, byte for byte what `zcube explain` prints. Codes
from Zigbox's registry (`ZBX-`) are served too, since a runtime diagnostic travels inside
observed state; the server gets their text from the linked `zigbox` module.

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
`ZBX-E0410`) is **held**, with a `hold_failed_replica` decision, and not retried or replaced.
