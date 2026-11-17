# The Jepsen battery: what Zigcube provides

The battery itself (a Clojure harness, `Zigbox/zigcube-jepsen`) runs on a throwaway Google Cloud
cluster (docs/decisions/2026-11-15-jepsen-on-google-cloud.md, docs/briefs/c5.md "Jepsen on Google
Cloud"). This file describes Zigcube's side of it: the workload client and the history it writes,
the read-only views a checker reads, and the properties a history is checked against.

PR `J` is split in two (supervisor, 2026-11-17; docs/decisions/2026-11-17-jepsen-j-split.md).
**J1** (this file's first version) builds the client, the views and the properties. **J2** adds
`zig build dist`, the deployment recipe in `ops/jepsen/` and the fault surfaces, and fills in
"Faults" below.

## The client: `zcube-jepsen-client`

A test-only binary, so the shipped `zcube` does not grow. `zig build jepsen-client` installs
`zig-out/bin/zcube-jepsen-client`; the default `zig build` does not build it.

```
zcube-jepsen-client --op apply|get|delete|watch --history FILE --process N --service NAME
    [--value N] [--from REVISION] [--hold-ms N] [--image DIGEST]
    [--server HOST:PORT] [--ca FILE --cert FILE --key FILE [--tls-name NAME]]
```

One run is one operation on one service, `NAME` (a service name, keys.md):

| `--op` | Request | Writes? | `value` on `:ok` |
|---|---|---|---|
| `apply` | `POST /v1/apply`: `NAME` with `replicas` = `--value`, image `--image` (default `jepsen:1`), command `sleep 1000000`, `applied_by` `jepsen` | yes | the count written |
| `get` | `GET /v1/list?prefix=/services/NAME&limit=1`, keeping only the key `/services/NAME` | no | the count read, or null when absent |
| `delete` | `DELETE /v1/services/NAME?applied_by=jepsen` | yes | null |
| `watch` | `GET /v1/watch?prefix=/services/NAME&from=--from&timeout=--hold-ms` (default 5,000 ms, at most 20,000) | no | the events of `/services/NAME` only, in order |

`--server` and the TLS flags mean what they mean for `zcube` (cli.md); the battery runs the
server with `--listen` and gives the client a certificate of scope `admin` (an apply needs it).

**The history file** is opened with `O_APPEND`. The client appends the invocation line before the
request leaves and the completion line after, each with one `write(2)`, so the lines of clients
running at once never interleave. The completion is also printed on stdout.

**Exit status:** 0 `:ok`, 1 `:fail`, 2 `:info`, 64 bad arguments (nothing written), 74 the history
file cannot be opened or written (the operation, if it ran, is not recorded: the harness must
treat the run as broken).

**A client the harness kills.** The connect has no timeout of its own (cli_http.zig: std's connect
takes none), so under a partition that drops packets a client waits until the kernel gives up
(about two minutes with Linux's default `tcp_syn_retries`); a reply waits at most
`cli_reply_timeout_ms` (30 s). The harness bounds each client with its own timeout and kills it
past that. A killed client leaves its `invoke` line with no completion, which the harness reads
as `info` (Jepsen's crashed process): the request may have been sent.

## The history

One JSON object per line. Members are always in this order, and one that does not apply is left
out; `value` is always present.

| Member | Meaning |
|---|---|
| `type` | `invoke`, then exactly one of `ok`, `fail`, `info` |
| `f` | `apply`, `get`, `delete`, `watch` |
| `process` | `--process` |
| `time` | nanoseconds of `CLOCK_BOOTTIME` on the client's host: monotonic, untouched by `date -s` |
| `service` | `NAME` |
| `value` | see the table above; an `invoke` of `apply` carries the count asked for |
| `from` | `watch`: the revision watched from |
| `revision` | the store revision the answer names (an `apply` that changed nothing names none) |
| `mod_revision` | `get`: the service key's `mod_revision`, when it exists |
| `action` | `apply` and `delete`: the server's `action` (`create`, `update`, `none`, `delete`) |
| `status` | the HTTP status, when a reply came |
| `code` | the diagnostic code: the server's first, or the client's own (`ZC-E0102`, `ZC-E0103`) |
| `request_id` | the server's `X-Request-Id`, to find the request in its log |
| `error` | the newest cause, in words |

A watch event is `{"type": "put"|"delete", "mod_revision": N, "replicas": N|null}`. The golden
files in `src/testdata/jepsen/` fix the encoding byte for byte.

```json
{"type":"invoke","f":"apply","process":1,"time":10,"service":"r1","value":3}
{"type":"ok","f":"apply","process":1,"time":19,"service":"r1","value":3,"revision":7,"action":"update","status":200,"request_id":"zc-…"}
```

### `ok`, `fail` and `info`

A write that may have committed is `info`, never `fail`: a checker treats `fail` as "did not
happen", and a `fail` that happened is a false linearizability violation. A read changes nothing,
so a read that did not answer is `fail`. As `test-store-faults` treats `ZC-E0213`:

| What came back | `apply`, `delete` | `get`, `watch` |
|---|---|---|
| a 2xx the client reads | `ok` | `ok` |
| a 2xx the client cannot read (`ZC-E0103`) | `info` | `fail` |
| no connection (`ZC-E0102`, nothing sent) | `fail` | `fail` |
| sent, then no reply (`ZC-E0102`) | `info` | `fail` |
| 4xx (refused before any write: `ZC-E0101`, `ZC-E0105`, a scope refusal) | `fail` | `fail` |
| 503 with `ZC-E0201` (the store was never reached) | `fail` | `fail` |
| any other non-2xx (`ZC-E0213`, 500, 502, …) | `info` | `fail` |

"Sent" means the connection was made (cli_http.zig's `Client.sent`): before that, no byte of the
request can have reached the server.

## The views: the state at one revision

`GET /v1/replicas?at=N`, `GET /v1/nodes?at=N` and the existing `GET /v1/jobs?at=N` (api.md) answer
what the store held at revision N, grouped by replica, by node and by job. A checker reads them at
the end of a run, and at revisions it chooses during one, to judge the invariants below on one
consistent snapshot. A view with `"truncated": true` is not judged. The brief named the parameter
`?revision=N`; it is `at=N` because `/v1/list` and `/v1/jobs` already use that name for that
meaning (a deviation, recorded in api.md and the decision file).

A snapshot is only as old as the compaction point: the harness must read the revisions it wants
before the server compacts past them (`410`, `ZC-E0203`).

## Properties

Each property names the source it is judged from: the **history** (the client's lines), a
**view** at a revision, or **host** observation (processes on the nodes, which the harness reads
over SSH; J2 says how). The sim's checks of the same name (authority.md §4 and §7, core.md
"sim-c1") are the definitions; these are what an outside observer can see of them.

### Services (the history)

- **L1. The service key is linearizable.** The `apply`, `get` and `delete` operations on one
  service, with `info` operations open-ended, are linearizable as a register whose value is the
  count or null (`apply` writes `value`, `delete` writes null, `get` reads). `apply` with action
  `none` is a write of the value already there.
- **L2. Revisions order writes.** The `ok` writes on one service, ordered by `revision`, are in
  real-time order: if A completed before B was invoked, A's revision is lower. No two `ok` writes
  name the same revision.
- **W1. A watch sees every write in its window, once, in order.** An `ok` watch's events have
  strictly increasing `mod_revision`s in `[from, revision]`, and include every `ok` write of the
  service with `revision` in that window (a put with that count, or a delete). An `info` write
  appears in a watch at most once and, if it does, counts as committed for L1.
- **W2. Reads agree with watches.** An `ok` get's `mod_revision`, when present, is the revision of
  a put some watch spanning it saw with the same count.

### Authority (views, at every revision the harness read)

- **I1a.** In `/v1/replicas`, every row has at most one `assigned` entry. (An `observed` entry on
  another node can remain for a while after a replacement; it is not admissible, and I1a is
  about ownership, not reports.)
- **I1b** (host). A replaced replica's old process and its replacement do not run at once for
  longer than `lost_grace_ms` plus kill latency, unless the old node was `SIGSTOP`ped (wedged) or
  its clock was moved beyond the skew bound; the harness records those overlaps and does not fail
  them, as the sim does.
- **I2.** Across the revisions read, a replica's placement epoch (its assignment's
  `mod_revision`) never goes backwards while the replica exists. A refused commit leaves no trace a
  view can show; this is the part of I2 an outcome shows.
- **I3.** Not visible from outside: a decision's evidence is in `/decisions/`, and `zcube why` (I5)
  is how an operator reads it. The harness runs `zcube why replica` for each replaced replica and
  judges I5 on the answer.
- **I4.** Not visible from outside (the writer of a transaction is not recorded); the sim checks
  it.
- **I5.** Every `zcube why` answer the harness asks for is `complete` or names its truncation.
- **I6.** In each `/v1/nodes` row, `allocation.value.allocated` equals the sum of the `requests` of
  the row's `assigned` records, and is within the node's declared capacity.
- **I7.** For every assignment created at revision P (its `create_revision`), the node's `status`
  at P−1 is `ready` (read `/v1/nodes?at=P-1`).

### Jobs (views and hosts)

The client has no job operations; the harness posts jobs with `zcube job` and reads them back with
`GET /v1/jobs?at=N` and `GET /v1/jobs/watch`. The checks a history and views can show:

- **J1** (host). A job's process is not alive more than the stated overlap after its terminal
  status.
- **J2** (host). No run id is started twice: the agent's start records, read from each node's
  state directory, name each run once.
- **J3** (views). A terminal job status never changes across revisions, and is never recreated
  while its job exists.
- **J4** (history of `GET /v1/jobs/watch`). A watcher that resumes from its revision sees every
  ending once.
- **J5** (views). A run whose `stop` is committed at revision S has no assignment created after S.
- **J6** (host). A run's process ends within `stop_bound_ms` of the `stop`'s commit.
- **J7** (views). Every run that reached `running` has a claim in `/job-observed/` under the
  tenure and epoch of its assignment, committed before any `stop`.
- **J8** (host and views). A run's process lives no longer than its deadline plus the bound, and
  after the cluster heals no run is open past its latest possible end.
- **J9** (views). Every stored `running` or `stopped` report names the run's current assignment.
- **J10** (host, at rest). No start record outlives its run's assignment.
- **J11** (views). A run that ended `exited` (or `oom`, `pid_limit`) was started by a node in its
  own incarnation (its claim's revision is above the run's create revision).

I8a and I8b (authority.md §7) are J3, J5 and J7, and J1 and J6, seen this way.

### Grants (pending C4)

- **G1. A destination refuses a caller without a grant** (pending C4). With C4's mesh, a dial to a
  replica's mesh port by a certificate that no grant names is refused by the destination, with
  C4's grant code. Not checkable before C4 merges: no code exists for it in J1.

## Faults

J2 fills this in: `SIGSTOP`/`SIGCONT` on any process, `iptables` partitions between any two hosts,
clock faults with `date -s` and NTP stopped, and killing and promoting Postgres.
