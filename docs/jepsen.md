# The Jepsen battery: what Zigcube provides

The battery itself (a Clojure harness, `Zigbox/zigcube-jepsen`) runs on a throwaway Google Cloud
cluster (docs/decisions/2026-11-15-jepsen-on-google-cloud.md, docs/briefs/c5.md "Jepsen on Google
Cloud"). This file describes Zigcube's side of it: the workload client and the history it writes,
the read-only views a checker reads, and the properties a history is checked against.

PR `J` is split in two (supervisor, 2026-11-17; docs/decisions/2026-11-17-jepsen-j-split.md).
**J1** (this file's first version) builds the client, the views and the properties. **J2** adds
`zig build dist`, the deployment recipe in `ops/jepsen/` and the fault surfaces, and fills in
"Faults" below (docs/decisions/2026-11-17-jepsen-j2-dist-and-recipe.md).

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
A flag given twice is refused, as is an `--image` that is empty or holds a quote, a backslash or
a control character (exit 64, nothing written).

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

**A process id is used once per outstanding operation.** After a completion of `info`, or a
client killed with no completion, the harness gives that worker a new `--process` (Jepsen's rule
for a crashed process): the old operation may still take effect, so the old process is never
idle, and a checker must not see a second operation of a process whose first has not ended.

**One clock per history.** `time` is the client host's boot clock, which means nothing on another
host. Every client that writes one history runs on one host (the control host, which the nemesis
never clock-skews), or the harness drops `time` and orders the lines by its own clock.

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
| `code` | the diagnostic code: the server's first, or the client's own (`ZC-E0102`, `ZC-E0103`, a TLS code such as `ZC-E0814`); a checker reads only `type` |
| `request_id` | the server's echo of `X-Request-Id` when a reply came, else the id the client sent; present whenever a request was attempted |
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
| sent, then no reply in time (`ZC-E0102`) or the connection cut (`ZC-E0103`) | `info` | `fail` |
| 4xx (refused before any write: `ZC-E0101`, `ZC-E0105`, a scope refusal) | `fail` | `fail` |
| 503 with `ZC-E0201` (the store was never reached) | `fail` | `fail` |
| any other non-2xx (`ZC-E0213`, 500, 502, …) | `info` | `fail` |

"Sent" means the connection was made (cli_http.zig's `Client.sent`): before that, no byte of the
request can have reached the server. The rule rests on `sent`, not on the code: a sent write
whose failure has no code is still `info`. `jepsen_client_test.zig`'s `socket:` tests run it over a
real socket (a listener that never accepts, one that reads and closes, a refused port).

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
over SSH; "Observing the hosts over SSH" below says how). The sim's checks of the same name
(authority.md §4 and §7, core.md "sim-c1") are the definitions; these are what an outside observer
can see of them.

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
  longer than `lost_grace_ms` plus kill latency, unless the old node was `SIGSTOP`ped (wedged),
  its clock was moved beyond the skew bound, or the store's clock stepped forward by more than
  `clock_step_max_ms`; the harness records those overlaps and does not fail them, as the sim does.
  The overlap alone can hide a late kill behind a slow replacement, so the harness also judges
  each old instance against its own **budget** (below), whatever its replacement did.

#### The declared bounds: `share/jepsen/fencing-bounds.edn`

`zig build dist` writes the fencing contract's constants (`src/constants.zig`) into the tarball as
an EDN map, from the same build as the executables beside it, so a checker reads the bounds of the
Zigcube it deploys and hard-codes none: `:lease-ttl-ms`, `:lost-grace-ms` (the defaults; a run
started with other values uses those), `:fence-margin-ms`, `:fence-window-min-ms`,
`:fence-stop-ms`, `:clock-skew-per-mille`, `:fence-kill-latency-ms`, `:kill-dispatch-ms`,
`:clock-step-max-ms`, `:fence-poll-ms`, `:stop-grace-ms`, and `:format 1` (a change of meaning
bumps it). With `skew = ceil(ttl × clock-skew-per-mille / 1000)` and the ttl and grace the run used:

- the agent's condition, `fence-margin-ms >= fence-stop-ms + skew + fence-kill-latency-ms`;
- the contract, `fence-margin-ms + lost-grace-ms >= fence-stop-ms + skew + fence-kill-latency-ms
  + kill-dispatch-ms + clock-step-max-ms` (`zcube-server` refuses a pair that fails either,
  ZC-E0121);
- **an instance's budget**: an instance on a node whose last accepted keepalive was at `s` (the
  node's own `CLOCK_BOOTTIME`) is dead by `s + ttl - fence-margin-ms + fence-stop-ms +
  fence-kill-latency-ms + kill-dispatch-ms`; on the store's clock, by the lease's expiry plus
  `lost-grace-ms` (the contract's slack is what is left), unless the node was wedged or a clock
  broke its bound. An instance that outlives it is a timing violation even with no overlap.
- **I2.** Across the revisions read, a replica's placement epoch (its assignment's
  `mod_revision`) never goes backwards while the replica exists. A refused commit leaves no trace a
  view can show; this is the part of I2 an outcome shows.
- **I3.** Not visible from outside: a decision's evidence is in `/decisions/`, and `zcube why` (I5)
  is how an operator reads it. The harness runs `zcube why replica` for each replaced replica and
  judges I5 on the answer.
- **I4.** Not visible from outside (the writer of a transaction is not recorded); the sim checks
  it.
- **I5.** Every `zcube why` answer the harness asks for is `complete` or names its truncation.
- **I6.** In each `/v1/nodes` row whose `node` record exists at that revision,
  `allocation.value.allocated` equals the sum of the `requests` of the row's `assigned` records,
  and is within the node's declared capacity. A row with no `node` (a node gone, its records not
  yet removed) is not judged.
- **I7.** For every assignment written at revision P (its `mod_revision`, the placement epoch),
  in `/v1/nodes?at=P-1` (the placement's transaction writes neither record, so P−1 and P agree)
  the node's row has a `node` record, its `status.value.tenure` equals that record's
  `mod_revision` (the status was written under the current tenure), and `status.value.state` is
  `ready`. This is authority.md's I7 as `sim-c1` checks it (`sim_checks.zig`, `ready_at`); a
  status with no `tenure` (a C0 record) fails it.

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

`ops/jepsen/fault.sh` makes each fault on one host, as root (`ops/jepsen/README.md` deploys the
cluster); `ops/jepsen/postgres.sh` crashes and promotes the database. What each fault does to
Zigcube, with the constants of authority.md (lease ttl 10 s, `fence_margin_ms` 3 s,
`lost_grace_ms` 1 s, clock skew 1 %), and what the checker must excuse:

### Pausing a process: `fault.sh pause|resume server|agent|postgres|PID`

`SIGSTOP`, then `SIGCONT`. `server` and `agent` are the units' main processes; `postgres` is the
postmaster and every child. `ops/jepsen/test-recipe.sh` (in `zig build test`, as root) pauses a
real server: a client's `get` gets no answer until the resume, then succeeds. Postgres is paused
postmaster first (it forks no new backend once stopped), then its children until a pass finds no
new one, and resumed children first; `ops/jepsen/test-postgres.sh` (CI's `jepsen` job) checks
that every process is stopped and a query hangs until the resume.

- **The server.** Clients' requests hang: the client is killed by the harness and records
  nothing, or the request ends `info` (unknown) after its timeout; L1 treats either as open. No
  agent can renew its lease: each fences at `ttl - fence_margin_ms` (7 s) after its last renewal
  on its own boot clock, stopping its replicas and jobs (jobs with cause `unreachable`). On
  Postgres the lease deadlines are the database's time (`clock_timestamp()`), which keeps
  running, so a pause longer than the ttl leaves every lease expired at the resume: the server
  finds every node lost and, after `lost_grace_ms`, replaces their replicas. Nothing overlaps (the
  old processes were fenced first); the checker sees replacements, not violations.
- **An agent** is a *wedged* node (authority.md §4): its lease runs out at the server, which
  replaces its replicas, while its own processes run on, since the paused agent cannot fence. I1b
  and I8b's overlaps on that node are excused, and so are J1, J6 and J8 for its runs, from the
  pause until `ttl - fence_margin_ms` after the resume (the agent then finds its lease gone and
  stops everything). The containers' supervisors are separate processes, not paused.
- **Postgres**: as the server, seen from the clients (every store call waits; after the store's
  timeout it fails with ZC-E0213 and is retried).

`fault.sh kill server|agent` sends `SIGKILL`. A killed agent leaves its containers running (each
under its own supervisor, and the unit has `KillMode=process`); started again
(`zigcube.sh agent ...` starts a unit that is not running), it adopts them. The units have
`Restart=no`: the harness decides when a killed process comes back.

### Partitions: `fault.sh partition HOST...` and `fault.sh heal`

Drops every packet to and from each HOST on this host (an `iptables` chain, `ZCUBE_JEPSEN`,
hooked first in `INPUT` and `OUTPUT`); `heal` empties the chain. For a cut between A and B, run
it on either (or both, for symmetry against stale conntrack state). The cuts that matter:

- **Client and server**: requests end `info` or the client is killed; L1 keeps them open.
- **Agent and server**: the agent fences at 7 s (replicas stopped; jobs stopped, cause
  `unreachable`); the server replaces after the lease expires plus `lost_grace_ms`. Fence before
  expiry is I1b's argument: no overlap is excused here.
- **Server and Postgres** (both hosts): every store call fails with ZC-E0213; leases are not
  renewed, so the effect is the server's pause, with errors instead of hangs.
- **Postgres primary and standby**: commits wait for the synchronous standby (`remote_apply`), so
  every write stalls and times out as ZC-E0213 until the heal; nothing acknowledged is lost.

### Clocks: `fault.sh clock-shift SECONDS`, `clock-set EPOCH`, `ntp-stop`, `ntp-start`

Each clock command stops NTP first (`timedatectl set-ntp false` and the NTP units), then steps
the wall clock with `date -s`; `ntp-start` lets it converge back. A step is not a rate skew: the
1 % bound of authority.md is on rates, and a step on the hosts below is outside it. Which clock
each host's step reaches:

- **The Postgres primary's host**: lease deadlines are the database's time. A forward step of at
  most `clock_step_max_ms` (500 ms) is inside the fencing contract and excuses nothing; a larger
  one (docs/operations.md, "Clocks", forbids it) expires leases early (a jump past the ttl expires every lease at once: replacements while the
  old nodes still run until their own fences, so I1b's overlaps are excused from the step to
  `ttl - fence_margin_ms` after it); a backward step lengthens leases, delaying replacement of a
  dead node (no violation, only latency).
- **The server's host**: its wall clock times `lost_grace_ms`, job deadlines and `start_by`
  judgments, decision timestamps, and the check of client certificates' validity. A forward step
  makes jobs miss deadlines early (J8 holds: the bound is on the late side), and past 7 days
  every certificate looks expired (ZC-E0814 at the handshake): keep server steps well under the
  certificates' remaining life, or re-issue (`ops/jepsen/README.md`).
- **A node's host**: nothing. The agent's fence and its jobs' deadlines run on `CLOCK_BOOTTIME`
  (its start records keep the boot id with them). A run's `started_at_ms` in its report is wall
  time and may look wrong; no property reads it.
- **The control host**: nothing. The client's history times are `CLOCK_BOOTTIME`.

### Postgres: `postgres.sh crash`, then `promote`

On the primary, `postgres.sh crash` kills the postmaster and its children with `SIGKILL` (no
checkpoint). On the standby, `postgres.sh promote` makes it a primary that runs alone. The
server's store names both hosts (`host=pg1,pg2 ... target_session_attrs=read-write`), so libpq
reaches the new primary: the calls in flight fail with ZC-E0213 (`info` to clients) and are
retried, and the server stays up. With the standby synchronous, no acknowledged write is lost (L1
and L2 hold across the failover; `zig build test-store-faults`' `sync` run checks the same).
The old primary rejoins as the new one's standby (`postgres.sh standby pg2 --allow CIDR
--rebuild`, then `sync-on` on `pg2`); `postgres.sh primary` refuses to start it as a second
primary.

### Observing the hosts over SSH

The host checks (I1b, J1, J2, J6, J8, J10) read each node's agent state directory,
`/var/lib/zcube-agent`, as root over SSH, by polling (every 200 ms, say) while the test runs and
once at rest. A container, replica or run, is `containers/<name>/` (a run's name is its run id):

- `supervisor.pid`: the supervisor, also the process group and session of the container.
- `child.pid`: the container's process, once started.
- `run.json`: present once the container has ended (its exit code or signal).

A process is alive when `kill -0 PID` succeeds and `/proc/PID/stat`'s start time is the one first
seen for that pid (pids are reused). Read the start time with the pid, as one observation:
`for d in containers/*/; do p=$(cat $d/child.pid 2>/dev/null) && echo "$d $p $(cut -d' ' -f22
/proc/$p/stat 2>/dev/null)"; done`, with the host's boot-clock time (`cat /proc/uptime`) as the
observation's time. The harness maps each observation to the control host's timeline by the
SSH round trip.

- **I1b, J1, J6, J8** compare the alive intervals of `child.pid` with the views' revisions (a
  replacement's commit, a terminal status, a stop's commit, a deadline), each with its bound.
  Excuse the windows of the faults above (a paused agent, a clock step on the primary's host).
- **J2**: `jobs/<run>.json` is the start record (`run`, `epoch`, `phase` `claiming` or `claimed`,
  `boot_id`). A run's record seen on two nodes, or with two `epoch`s, or a run's `child.pid`
  whose (pid, start time) changes, is a second start. A start that begins and ends between two
  polls can be missed: polling bounds what J2 can see.
- **J10** (at rest, after the heal and a few ttls): every `jobs/<run>.json` names a run that
  `/v1/jobs` still shows assigned to that node.
