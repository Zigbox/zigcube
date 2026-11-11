# The `zcube` command line

`zcube` talks to `zcube-server` over the HTTP API ([api.md](api.md)) and nothing else: it opens no
store and starts no process, with one exception: [`zcube local`](#local-up-and-down) starts the
server and the agent on this machine. Every command below was run against a real `zcube-server` on SQLite
to write this page; the end-to-end test (`src/cli_test.zig`) runs them again on every `zig build
test`. It is C0 slice 6b, which also holds the diagnostics machinery ([DIAGNOSTICS.md](../DIAGNOSTICS.md)).
It is not `demo-c0`: that needs the real agent.

```
zcube [options] apply <file.zon>        show what the file would change, then apply it
zcube [options] delete service <name>   delete a service; its replicas are stopped
zcube [options] get service [name]      services and how many replicas run
zcube [options] get replicas [service]  replicas, where they run and how they are doing
zcube [options] get nodes [name]        nodes, their status, lease, capacity and last contact
zcube [options] why <kind> <name>       why a service, replica or node is as it is
zcube [options] stats pull [node]       what pulls moved, by source (registry, peers, cache)
zcube [options] check allocations       every node's allocation record against its assignments
zcube [options] repair allocations <node> [--confirm]
                                        rewrite a node's record from its assignments
zcube [options] job run <name> --image <digest> [--env K=V] [--input-file F --input-env VAR]
                [--relay NAME] [--deadline 10m] [--submit-within 10m] [--label k=v]
                --command <word>...
zcube [options] job get <name> [--wait]  a job's state and ending; --wait waits for the ending
zcube [options] job list [--state S] [--label k=v]
zcube [options] job cancel <name>        stop a job
zcube [options] job watch [--from REV]   one line per ending, as they happen
zcube [options] explain <code>          explain a diagnostic code, offline
zcube [options] bundle --last           the evidence for the last failure
zcube [options] bundle <kind> <name>    the evidence for a service, replica or node
zcube help | version
```

| Option | Meaning |
| --- | --- |
| `-v`, `--verbose` | the full cause chain and context of a failure; every request made, with its id |
| `-o`, `--output text\|wide\|json` | `wide` adds columns to `get` and `stats pull`; `json` is for scripts (below) |
| `--server HOST:PORT` | where `zcube-server` listens: this flag, else `$ZCUBE_SERVER`, else `127.0.0.1:7070`. An IP address (or `localhost`) and a port |
| `-y`, `--yes` | `apply`, `delete`: do not ask first |
| `--dry-run` | `apply`: show the change and stop |
| `--no-redact` | `bundle`: keep secrets in the bundle (prints a warning) |
| `--confirm` | `repair allocations`, `store accept-rollback`: do it (without it, say what it would do) |

Options may come before or after the command. `--` ends them. Anything else that starts with `-`
is `ZC-E0111`.

## apply and delete

`zcube apply hello.zon` parses the file, asks the server what applying it would change
(`POST /v1/apply?dry_run=1`), prints that, asks, and only then writes (`POST /v1/apply`):

```
$ zcube apply hello.zon
service hello: would update
  replicas 3 → 5
apply? [y/N] y
applied service hello: replicas 3 → 5
```

- A file that is already what is stored prints `service hello: unchanged` and asks nothing.
- `--yes` skips the question. **Without a terminal on standard input and without `--yes` it fails
  with `ZC-E0113`; it never waits and never guesses.** An answer that is not `y` or `yes` (or the end
  of the input) is `ZC-E0114`. `--dry-run` shows the change and stops.
- The service file is HANDOFF's example: `.name`, `.image`, `.replicas`, `.command`, and optionally
  `.env` (pairs of strings), `.limits` (`.cpu_millis`, `.memory_bytes`) and `.source` (C2 slice 2:
  the OCI reference the image is pulled from when the node does not have it, pinned by digest, as
  `registry.example/hello@sha256:<64 hex digits>`; `zbx pull` prints the reference and the digest.
  `apply` refuses a tag, with `ZC-E0104`). Leave `.source` out and the tree must already be on the
  node. `get service -o wide` and `get replicas -o wide` gain a `SOURCE` column, and `-o json`
  a `source` member, only for a service that has one. An unknown field is an
  error, so a typo is not silently ignored. Every problem is `ZC-E0110` with the file, line and
  column and the line itself (`--verbose`); a file that can't be read is `ZC-E0109` (any file a command names: the service file, the input file of `job run`). Nothing is
  sent before the file is valid.
- The change is recorded as `user@host` (`$USER` and the host name); the server does not check it
  (writes are unauthenticated until auth exists, [api.md](api.md)).
- `zcube delete service hello` says what is running (`2/2 running; its replicas will be stopped`),
  asks the same way, and calls `DELETE /v1/services/hello`. It is not in the brief's command list;
  the approved write endpoint needs a caller, and the end-to-end test needs to delete.

## get

```
$ zcube get service
NAME   READY  IMAGE
hello  3/3    b3:51aa9c03

$ zcube get replicas hello -o wide
REPLICA  SERVICE  NODE   STATUS   AGE  GEN  CPU   MEMORY  IMAGE        DETAIL
hello-1  hello    node1  running  8s   1    250m  128Mi   b3:51aa9c03
hello-2  hello    node2  running  8s   1    250m  128Mi   b3:51aa9c03
hello-3  hello    node3  running  8s   1    250m  128Mi   b3:51aa9c03

$ zcube get nodes
NODE   STATUS  TENURE  LEASE     CAPACITY       ALLOCATED     LAST-HEARD
node1  ready   1       8.3s/10s  4000m / 8.0Gi  250m / 128Mi  1s ago
node2  ready   2       8.3s/10s  4000m / 8.0Gi  250m / 128Mi  1s ago
node3  ready   4       8.3s/10s  4000m / 8.0Gi  250m / 128Mi  1s ago
```

(Both from one run of `demo/up.sh` and `zcube apply` of a 3-replica `hello`.)

`CPU` and `MEMORY` (wide) are the `requests` of the replica's `/assigned/<node>/<id>`, what the
scheduler resolved it to need; `-` while it is unassigned.

`get nodes` joins `/nodes/`, `/node-status/`, `/allocations/` and `GET /v1/leases`; the rows are
the names under `/nodes/` and `/node-status/` together. `STATUS` is the node controller's `state`
as stored (`-` before it has judged the node); `ready*` means the status is for an earlier tenure
than the registration, which the scheduler does not count. `TENURE` is the `/nodes/<node>`
revision. `LEASE` is remaining over ttl. `LAST-HEARD` is `ttl - remaining` of the lease, against
the server's clock: a keepalive creates no revision, so the lease is the only record of contact;
`-` when the node has no lease. `-o wide` adds `ADDRESS`, `AGENT`, `REPLICAS` and `LEASE-ID`.
`get nodes node2` shows one node; an unknown name is `ZC-E0101`.

The output above is `demo/up.sh` (three nodes, one `hello` service of 3 replicas); `demo/kill-node.sh
node2` kills a node's agent and containers with `kill -9`, and `demo/down.sh` stops everything.

`READY` is running replicas over desired. `STATUS` is the agent's report: `running`, `starting`,
`exited`, `killed`, `oom`, `pid-limit`, `start-failed`, `lost`, or `pending` (no report yet). `DETAIL`
is the diagnostic of a failed start (`ZBX-E0410: no tree with that digest`) or how it exited. `AGE` is
measured against the server's clock, not the laptop's. The command reads `/services/`, `/replicas/`
and `/observed/` with `GET /v1/list` and joins them (docs/keys.md is the contract).

## why

`zcube why service broken` prints the server's chain, word for word (`state.text`, then `←` and
each step's `text`); a step that carries a diagnostic is the full diagnostic block under its arrow.
With a service that is running and no agent:

```
$ zcube why service hello
service hello: 0/3 running
  ← service hello wants 3 replicas and 0 exist
  ← service hello was applied by alex@vm (request zc-1a17d73d194-eef1d8de-2): generation 1, 3 replicas
```

With a digest that is not in the node's store (this is the end-to-end test's expected output):

```
service broken: 0/1 running
  ← replica broken-1 failed to start on node1; it was not replaced because a new one would fail the same way
  ← error[ZBX-E0410]: no tree with that digest
      cause  digest b3:00ff7be1 is not in this node's store
      fix    check the digest in the service file, or pull the image first
      more   zbx explain E0410 · rerun with --verbose for the full cause chain
      docs   https://zigbox.github.io/zigbox/errors/E0410.html
```

`--verbose` adds each decision's id, actor and action, and the full cause chain of a diagnostic step,
and a last line on whether the chain reaches its cause: `completeness: complete`, or
`completeness: truncated (retention) at <decision id>`; the reason is `retention`,
`subject_deleted` or `compacted` (api.md). Without the field (an older server) the line is left out.

`zcube why node node3` starts from the state line, which names the judgement and the load
(`node node3: ready (tenure 22), lease 9 with 0 replicas assigned, 0m of 4000m CPU and 0B of
8.0Gi memory in use`), then the node's newest decision. A `ready` node that holds fewer
replicas than another gets one more line, a note and not a reading of the store: replicas already
running elsewhere are not moved back, because the scheduler places a replica when it is created or
its node is lost and does not rebalance.

## check and repair allocations

The scheduler keeps a record per node of what it has placed there (`/allocations/<node>`,
[keys.md](keys.md)); the allocation auditor rebuilds that total from the node's assignments after
every scheduler pass and opens a finding (`ZC-B0003`, in `zcube why node`) on a node where they
disagree. The scheduler places nothing on such a node until it is repaired.
`zcube check allocations` (`GET /v1/check/allocations`, [api.md](api.md)) shows both totals for
every node, as assignments, cpu millis and memory bytes:

```
NODE   RECORDED        ASSIGNED        AGREE  FINDING
node1  3, 300m, 3072B  2, 200m, 2048B  NO     0000000000042-0003-0001
node2  none            0, 0m, 0B       yes    -
at revision 7: 1 of 2 nodes disagree (assignments, cpu, memory)
```

It exits 0 when every node agrees and fails with `ZC-E0404` (exit 1) when one does not, so a
script notices; `-o json` prints the server's answer as it is. `zcube repair allocations node1`
says what it would write and stops (`ZC-E0401`); with `--confirm` it writes, records a
`repair_allocation` decision that cites the finding, and prints
`repaired node1: recorded 3, 300m, 3072B, now 2, 200m, 2048B (revision 8, decision …)`. A node with
no open finding is `ZC-E0402`; one whose accounting kept moving during the request is `ZC-E0403`
(run it again). The texts above are the CLI's unit and golden tests (`src/cli_allocations.zig`,
`src/testdata/cli/E040*.txt`).

## stats pull (C2 slice 7)

`zcube stats pull [node]` reads `GET /v1/stats/pull` (docs/api.md) and prints one row per
recorded pull, newest first, at most 50:

```
NODE   TREE             REGISTRY  PEERS  CACHED  TOOK  BAD PEERS
node1  b3:51aa9c03...   1Mi       2Mi    0B      4s    node3
```

The digest is cut to 15 bytes and "..." (the table pads by bytes, so the ellipsis is ASCII);
`-o wide` prints it whole and adds `FROM PEERS` (`node2=2Mi,...`). `-o json` is the reply.
No pulls prints `no pulls have been recorded` and is not an error. Under the table, one line each
for records that could not be read (`1 record could not be read`), pulls the server read but the
50-row limit left out (`3 more not shown`), and a server that stopped at its own cap (`the server
read only part of the records`). A node name is percent-encoded in the request. Code:
`src/cli_stats.zig`; tests there and in
`src/cli_test.zig` (against a live server).

## job (B1 slice 7)

`job run` submits a one-shot job (`POST /v1/jobs`, [api.md](api.md)). `--command` must be last: it
ends the options and everything after it is the job's command, word for word. `--env K=V` may
repeat; `--input-file F` (UTF-8, at most 64 KiB) is the job's input and `--input-env VAR` names the
variable it reaches the job in. `--relay NAME` asks for the named relay from the server's
configuration: the job reaches that upstream through `ZCUBE_RELAY` (B3, [api.md](api.md)). `--deadline` and `--submit-within` take `30s`, `10m`, `2h`;
`--submit-within` becomes an absolute `submit_by` from the clock of the machine running `zcube`.

**Env values and the input are never printed.** `job get` shows env by name and the input as "N
bytes, given as VAR"; the failure record and bundles keep `--env K=...` and read
`/v1/job-status/<name>`, never `/v1/jobs/<name>`; JSON output carries the same names, not values.

`job get --wait` asks again once a second until the job has ended, then exits with a code of its own:

| Exit | Meaning |
| --- | --- |
| `0` | exited with code 0 |
| `10` | exited otherwise (a code or a signal) |
| `11` | failed (deadline, lost node, out of memory, ...) |
| `12` | cancelled |
| `1`, `2`, `3`, `70` | the command itself failed, as everywhere |

`job list` prints NAME, STATE, NODE and END (`wide` adds IMAGE, LABELS, DEADLINE); `no jobs` when
none match. `--state` is a job state or `ended`. `job watch` prints one line per ending
(`etl  exited (code 0)  node1`; `--output json`: `{"name","status"}`), and `--from REV` is the
first revision wanted. After every answer that held an ending, and every relist, `watch` writes
`watching: resume with --from N` to stderr (stdout, `--output json` too, keeps its shape); pass that
`N` to continue from there. Each round of the watch frees its own memory, so a watch that runs for
days stays the size it started. `job get` shows `cancel requested by WHO` once a cancel is recorded. If the server answers `ZC-E0203` (that revision was compacted), `watch` lists the
ended jobs, skips those it has already printed (by name and epoch) and goes on from the list's
revision. The dedupe holds `job_admitted_window_max` (8,192) keys, the most ended jobs the server keeps,
so each ending prints once however often the watch relists. A relist prints every ended job
the server still has, including those from before the watch began or before `--from` (a listed
row carries no revision to tell them apart); a server that compacts past a listing's page
restarts the listing (up to 8 times, then `ZC-E0103`); a list of more than 1,024 pages is
`ZC-E0103`.

`job logs` is not here: slice 8 is cut.

## explain

`zcube explain E0201` (also `ZC-E0201`, in any letter case) prints the registry's long explanation,
offline. `ZBX-` codes come from Zigbox's registry through the linked `zigbox` module, plus the
placeholder runtime codes of [runtime-codes.md](runtime-codes.md). The same text is generated into
`site/errors/<code>.html`, the `docs` link of every `ZC-` diagnostic. An unknown code is `ZC-E0118`.

## Output modes and exit codes

| Mode | Standard output | Standard error |
| --- | --- | --- |
| default | the result | the diagnostic: summary, innermost cause, fixes, `more` and `docs` |
| `--verbose` | the result | plus the cause chain, context (`server`, `reqid`, ...) and one line per request |
| `--output json` | the result as JSON | one JSON object per diagnostic, one per line |

Exit codes follow DIAGNOSTICS.md and the blame of the **first** diagnostic: `0` ok, `1` your input,
`2` your environment, `3` an external service (the store), `70` a bug. `job get --wait` adds `10`,
`11` and `12` for a job that ended (see [job](#job-b1-slice-7)). A warning (`ZC-W0119`) does not
change the exit code.

JSON on standard output, for `--output json`:

| Command | Shape |
| --- | --- |
| `get service` | `{"kind":"service","items":[{"name","image","desired","running","generation","applied_by","command"}]}` |
| `get replicas` | `{"kind":"replicas","items":[{"id","service","node","generation","image","status","detail","started_at_ms","requests"}]}` (`requests`: `{"cpu_millis","memory_bytes"}` or null) |
| `get nodes` | `{"kind":"nodes","items":[{"name","status","status_tenure","tenure","lease":{"id","ttl_ms","remaining_ms"},"capacity":{"cpu_millis","memory_bytes"},"allocated":{"cpu_millis","memory_bytes"},"count","last_heard_ms_ago","address","agent_version"}]}` (`status`, `status_tenure`, `tenure`, `lease`, `capacity`, `last_heard_ms_ago` are null when unknown) |
| `why` | the server's body of `GET /v1/why`, unchanged |
| `apply`, `delete` | the server's answer (`action`, `change`, `revision`, `decision`, ...), unchanged |
| `job get`, `job list` | the server's body, with env values and the input left out |
| `job watch` | one object per ending, per line: `{"name","status"}` |
| `explain` | `{"code","severity","blame","summary","explanation","exit_code"}` |
| `bundle` | `{"path","redacted","manifest"}` |

JSON mode never prompts: `apply` and `delete` need `--yes`, unless standard input is a terminal, in
which case the question is the one line of standard error that is not JSON.

### A server that is not there

```
$ zcube get service
error[ZC-E0102]: can't reach zcube-server
  cause  connection refused: nothing is listening there
  fix    start it:                          zcube-server --store sqlite:zcube.db --create-store
         or name the one that is running:   zcube --server HOST:PORT get service
  more   zcube explain E0102 · rerun with --verbose for the full cause chain
  docs   https://zigbox.github.io/zigcube/errors/E0102.html
```

`--verbose` adds `while sending a request to zcube-server`, the second cause (`no answer from
zcube-server at 127.0.0.1:7070`) and the context `server` and `reqid`. A reply that is not what the
API promises is `ZC-E0103`. When the *store* is down, the server answers 503 and the diagnostic is
the server's own (`ZC-E0201`), shown unchanged.

## Request ids

Every request carries an `X-Request-Id` (`zc-<time>-<random>-<n>`), which the server uses as its
own. `--verbose` prints each request's id, method, path and status on standard error; a failed
request's id is the `reqid` context of its diagnostic (`--verbose`, JSON) and `request id` in the
bundle's `command.txt`, so a CLI error can be matched to the server's log.

## Bundles

`zcube bundle --last` (or `<kind> <name>`) writes one `.tar.gz` in
`$XDG_STATE_HOME/zcube/bundles/` (else `$HOME/.local/state/zcube/bundles/`, mode `0600`, written
under a temporary name and renamed) and prints its path and its manifest. **It never leaves the
machine.** Files sit under one directory named like the bundle (`<UTC time>-<label>`):

| File | What |
| --- | --- |
| `MANIFEST.txt` | every file and why; what was cut at a bound; how many values were redacted |
| `command.txt` | the command, the server, the request id |
| `diagnostic.json` | the diagnostics, as `--output json` prints them (for `--last`) |
| `version.txt`, `uname.txt`, `os-release.txt` | zcube's version and build, kernel release and machine (not the host name), distribution |
| `environment.txt` | the names of the environment variables; every value is `[redacted:env]` |
| `status.json` | `GET /v1/status` |
| `why.json` | `GET /v1/why/<kind>/<name>`: the decision chain |
| `keys/*.json` | the store keys of the subject (`GET /v1/list`), **at the failing revision** when it is known and still there, else now (the manifest says which) |

The evidence from the server is best effort: a server that is down is the usual reason to want a
bundle, so each piece that can't be had is a `<name>.unavailable.txt` holding the diagnostic that
says why. Files are cut at 128 KiB and the manifest says so.

**Redaction** is on by default and `--no-redact` prints `ZC-W0119`. Four layers:

1. every environment value is `[redacted:env]` (the names stay);
2. the values of secret-named environment variables of the `zcube` process are removed wherever
   they appear in any file;
3. every `env` value in a store record (`keys/*.json`) is replaced, whatever its name
   (`bundle_redact.zig`, `redact_env_values`);
4. Zigbox's redactor, ported: private keys, well-known token shapes, `Bearer` and `Authorization`,
   and `NAME=value`, `--name value` and JSON/ZON pairs for names containing `token`, `secret`,
   `password`, `passwd`, `passphrase`, `credential` or ending in `key`.

It is a net, not a proof (an innocent-named secret in a free-text field can pass), which is why the
manifest says to read every file before sharing.

**A `bug` diagnostic writes a bundle by itself**, also when the server reported the bug; the path
is the diagnostic's `saved` line. A panic does not (a panic handler that wrote one could panic).

**The last failure** is remembered in `$XDG_STATE_HOME/zcube/last-failure.json` (the diagnostics,
the command, the server, the request id, the subject and the revision when the answer had one) by
every failing command except `bundle` and the ones that need no server. That is what `--last`
reads; with none it is `ZC-E0117`.

## Codes the command line raises

`ZC-E0101` to `E0108` are documented in [api.md](api.md); the command line raises `E0101` (a service
that does not exist), `E0102`, `E0103` and relays the rest from the server, as it relays the
repair's `ZC-E0401` to `E0403` ([api.md](api.md)).

| Code | Blame | Summary |
| --- | --- | --- |
| `ZC-E0109` | user | a file named on the command line can't be read |
| `ZC-E0110` | user | the service file isn't valid |
| `ZC-E0111` | user | the command line can't be understood |
| `ZC-E0112` | user | the server address can't be used |
| `ZC-E0113` | user | apply needs an answer and there is no terminal |
| `ZC-E0114` | user | the apply was declined |
| `ZC-E0115` | environment | can't write the output |
| `ZC-E0116` | environment | can't use the state directory |
| `ZC-E0117` | user | there is no failure to bundle |
| `ZC-E0118` | user | no such diagnostic code |
| `ZC-W0119` | (warning) | `--no-redact` keeps secrets in the bundle |
| `ZC-E0120` | environment | zcube ran out of memory |
| `ZC-E0121` | user | the lease ttl is one an agent cannot fence in time |
| `ZC-E0122` | environment | `zcube local` can't find or start the server or agent |
| `ZC-E0123` | environment | the local server or agent did not come up |
| `ZC-E0124` | environment | another `zcube local` command held the lock for 60 s |
| `ZC-E0404` | user | a node's accounting disagrees with its assignments (`check allocations`, exit 1) |
| `ZC-B0002` | internal | zcube failed in a way it should not (a command failed and said nothing) |

## local up and down

`zcube local up` runs a whole control plane on this machine, detached, so `zcube apply` has
something to talk to. This is the one command that is not an HTTP client: it lives in
`src/cli_local.zig`, outside the wasm core, and starts `zcube-server` (SQLite) and `zcube-agent`
(`FakeRuntime`, node `local`), which it finds beside the `zcube` executable (E0122 if they are not
there). It waits for `GET /v1/status` and for the node to be registered (E0123 if either does not
happen within 20 s; the fix names the log), then prints the address, `export ZCUBE_SERVER=...` and
`zcube apply hello.zon`.

```
$ zcube local up
local: up
  server  127.0.0.1:7070 (pid 1027), log /tmp/zl1/server.log
  agent   node local (pid 1028), log /tmp/zl1/agent.log
  state   /tmp/zl1
next:
  export ZCUBE_SERVER=127.0.0.1:7070
  zcube apply hello.zon
```

- The directory (mode `0700`) is also the scope of a lock: `up` and `down` hold an exclusive
  `flock` on `<dir>/lock` for their whole run, so two at once take turns; one that waits 60 s
  gives up with E0124. Logs are kept: the previous `server.log` and `agent.log` become `.log.1`.
- State is in `$ZCUBE_LOCAL_DIR`, else `$XDG_STATE_HOME/zcube/local`, else
  `~/.local/state/zcube/local`: pid files, logs, the SQLite file, the agent's state directory.
- The port is 7070, or the next free one; a later `up` prefers the port the last one used.
- `up` when both run says `local: already running` and changes nothing. If only one runs, `up`
  stops it and starts both together.
- `zcube local down` sends SIGTERM, waits, then SIGKILL, agent first. The containers are not
  stopped: the next `up` adopts them, with no duplicates. `down` with nothing running says so.
- A pid file is `<pid> <start time>`. It counts only if the process exists, is not a zombie, has
  that start time (`/proc/<pid>/stat`, field 22: a recycled pid has another) and its command line
  is exactly ours: the server with `--store sqlite:<dir>/zcube.db`, the agent with
  `--state-dir <dir>/agent`, and not a `supervise` process. Otherwise it is stale and deleted,
  never signalled. A process that will not stop (EPERM) keeps its pid file.
- `down` names only the processes it stopped.
- `up` is ready when the server answers, the new agent's log says it registered, and the node is
  in the store: an earlier run's registration proves nothing. The server and agent start with no
  inherited descriptors above 2.
- `zig build local-smoke` (`src/local_smoke.zig`) runs the sequence, two concurrent `up`s and a
  `down` after the agent died, on copies of the executables the build made.

## Chunk store flags of `zcube-agent`

`zcube` does not start the peer swarm: `zcube local up` runs its agent with no chunk store. A node
joins the swarm with two flags of `zcube-agent` itself (they are in `zcube-agent --help`, and
`docs/agent.md` says what they do): `--images-dir DIR` gives the node a chunk store, and
`--peer-listen HOST:PORT` (needs `--images-dir`; with `--runtime zigbox` it serves the Zigbox store instead) serves it to peers over the authenticated
handshake, rate limited (ZC-E0808, `docs/peer.md`, "Rate limit"). `--registry HOST:PORT` is where
an image no peer has is fetched from (also needs `--images-dir`). `--peer-advertise HOST:PORT` is
the address published for peers; it is required when `--peer-listen` names `0.0.0.0` or `::`.

## How it is tested

- **Golden tests** (`src/cli_golden.zig`, `src/testdata/cli/`): every registered `ZC-` code has its
  default, verbose and JSON output checked in. The files are embedded at compile time, so a code
  without its three files does not compile, and a test fails if a code has no case. A *raised* case
  runs the real command line; a *relayed* case is a canned server reply, so it pins how the command
  line shows a diagnostic that the server, the store or the runtime raises (those conditions are
  tested where they are raised). Changing a message: `ZCUBE_GOLDEN_UPDATE=$PWD/src/testdata/cli zig
  build test` rewrites the files, and the diff is the review.
- **No stack trace** (same file): every case in every mode, both streams, must show no trace,
  source location, address or raw Zig error name.
- **Bundle redaction** (`src/cli_test.zig`): fake secrets in the environment and in a service's
  `env` must not appear in any file of the bundle; `--no-redact` must keep them and warn.
  `src/bundle_redact_fuzz.zig` plants secrets in the shapes the redactor claims to cover (a port of
  Zigbox's fuzzer); a failure prints the seed, and `ZCUBE_FUZZ_SEED=<n>` replays it.
- **End to end** (`src/cli_test.zig`): a live server on SQLite, a simulated agent, and the command
  line in-process: apply, get, why, scale, delete, a declined apply, a dry run, JSON output, an
  unreachable server, bundles. Jobs (slice 7): run, `get --wait`, cancel, list and `watch --from`
  against the live server (a cancelled job that never ran needs no agent), and that no env value or
  input appears in any output; a scripted transport walks the 410 relist and its dedupe.

## Known gaps

- **No connect timeout.** The standard library's `connect` does not implement one yet (it panics
  when given one), so a host that silently drops packets keeps `zcube` waiting until the kernel gives
  up. A refused connection is immediate, and a server that accepts and then says nothing is
  `ZC-E0102` after 30 s without a byte (`poll` on the socket; a receive timeout on the socket makes
  the standard library's reader panic, so `cli_http.zig` reads the socket itself).
- Two bundles with the same label in the same second overwrite each other.
- `apply` shows the plan, then asks, then writes; if someone else changed the service in between,
  the write is planned again (up to three times, [api.md](api.md)) and the *applied* line is the final
  change, which may differ from the plan that was shown.
- The reply is read by its `Content-Length`, and `zcube` closes the connection first (it sends no
  `Connection: close`): whoever closes first keeps the connection in `TIME_WAIT` on its port for a
  minute; the server no longer depends on this (docs/core.md, `SO_REUSEADDR`), but closing first is still good manners. A reply with no
  length is read to the end of the connection; a chunked reply is `ZC-E0103`. The server never
  sends either.
