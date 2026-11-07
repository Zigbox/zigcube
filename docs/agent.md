# The node agent

**Status: C0 slice 6a (2026-10-27).** What `zcube-agent` is made of, how `FakeRuntime` runs real
processes under the supervisor model, what survives what, and what building it showed about the
`Runtime` contract. The agent's endpoints are in [api.md](api.md) ("Agent endpoints (slice 6a)");
the decision-making is `src/agent.zig`, described in [core.md](core.md).

## The pieces

What moved into the core in slice 2b, so that the cluster simulator runs the code production runs:
the loop policy (`agent_loop.zig`, out of `agent_run.zig`, which keeps the process, the signal and
the real wait), the endpoint client (`agent_client.zig`, out of `agent_remote.zig`, which keeps the
HTTP transport), what the agent persists (`AgentState` in `agent_state.zig`, with `DirState` as the
shell's files) and the container records (`agent_records.zig`, shared with `FakeRuntime`).

| File | Core or shell | What it is |
| --- | --- | --- |
| `agent.zig` | core | The reconcile step: desired replicas against what the runtime lists |
| `agent_api.zig` | core | The server's side of the agent endpoints, bytes in and bytes out |
| `agent_client.zig` | core | `Store` implemented over those endpoints, on a `Transport` (a call that may not answer) |
| `agent_loop.zig` | core | The loop policy as a state machine over virtual time: step, pause, watch, stop; what to report |
| `agent_records.zig` | core | The container records (`spec.json`, `run.json`), the order of their writes, `scan`, and `classify`: the one record layer for `FakeRuntime` and the simulator |
| `agent_state.zig` | core | `AgentState` (what the agent persists) and `SimState`, which models the files and crashes at write points |
| `agent_remote.zig` | shell | `HttpTransport`: the `Transport` over the HTTP client |
| `agent_http.zig` | shell | The HTTP client: one request per connection, the agent closes first |
| `agent_run.zig` | shell | The loop: step, wait, report failures once, back off, stop on a signal |
| `agent_config.zig` | shell | Flags and the ZON file; the images fixture |
| `zcube_agent.zig` | shell | The process: panic handler, exit codes, `supervise` mode |
| `fake_runtime.zig` | shell | `Runtime` with real host processes |
| `fake_supervisor.zig` | shell | `zcube-agent supervise <dir>`: one container's supervisor |
| `fake_files.zig` | shell | The files the agent and a supervisor meet in; `DirState` is `AgentState` over them |
| `sim_node.zig` | core | One simulated node: `SimRuntime` plus `SimState` joined by `agent_records`, with crashes at write points and step boundaries |
| `sim_clock.zig`, `sim_net.zig`, `sim_store.zig`, `sim_cluster.zig` | core | The simulator's node clocks, network, lost acknowledgements and the world that runs the agents of N nodes ([core.md](core.md#the-cluster-simulation)) |
| `agent_smoke.zig` | test | `zig build agent-smoke`, the server and agent as real processes |

The agent is single-threaded. Nothing in it can race what it starts, and `zbx`'s `start` needs a
single-threaded caller (HANDOFF, the recorded exception).

## Running it

```
zcube-agent --node node1 --server 127.0.0.1:7070 --state-dir /var/lib/zcube-agent \
            --cpu-millis 4000 --memory-bytes 8589934592
```

Everything can also be set in a ZON file (`--config FILE`); flags win. `--help` lists the rest.
The images the fake runtime "has" are read from `fixtures/images.zon` (`--images FILE`); any other
digest is `start_failed` with the placeholder `ZBX-E0410` ([runtime-codes.md](runtime-codes.md)),
unless `--registry` gives it a registry to fetch from (below).
Capacity is declared, as HANDOFF's provisional answer says.

Start-up failures are `ZC-E0505` (configuration) or `ZC-E0506` (state directory) on stderr with
the exit code of their blame. While it runs, a server that cannot be reached is `ZC-E0503`, shown
once and again every 30 seconds, with a backoff from 250 ms to 5 s. SIGINT or SIGTERM ends the
agent and leaves the containers running.

## One container

Each container is a directory `<state>/containers/<replica id>/`:

| File | Written by | Holds |
| --- | --- | --- |
| `spec.json` | the agent, before the supervisor starts | name, image, command, env, labels, start time |
| `lock` | held by the supervisor | an `flock` for as long as the supervisor lives |
| `supervisor.pid` | the supervisor | its pid, which is also its process group and session |
| `child.pid` | the supervisor | the command's pid, once it runs |
| `forced` | a test fault | `oom` or `pid_limit`, before the kill |
| `fetch.json` | the runtime, when the image must be fetched first | `{digest, argv}`: the `zcube-agent fetch` command the supervisor runs before the command |
| `fetch.log` | the fetch's stderr, while and after it runs | the text of ZC-W0601 and ZC-E0601, when they are raised; the supervisor appends ZC-W0603 for a fetch that failed, was killed at its deadline or did not start (the registry pull follows; the fetch's own ZC-E0601 is the fetch's line), a line saying no fetch was needed when the tree was already in the store, and ZC-W0504 when it cannot write `pull.json`; a line when the supervisor's registry pull starts and one with its outcome, and, while a fetch asks peers for chunks, a progress line (elapsed time, chunks asked, bytes from peers and from the registry, the last source) at most every `fetch_progress_ms` (10 s) from the fetch's first clock read, also while it waits or a request is out, so a stalled fetch is told apart from a slow one (issue #93) |
| `run.json` | the supervisor, last | how the command ended; the truth for `list` and `inspect` |

`start` writes the spec and starts `zcube-agent supervise <dir>`, then waits (at most
`fake_start_timeout_ms`) for `child.pid` or `run.json`. The supervisor starts a session of its own,
takes the lock, runs the command with the spec's environment and no terminal (stdio is
`/dev/null`), records the pid, waits for it, and writes `run.json`. A `SIGTERM` to the supervisor
is passed to the command.

**Re-adoption is `list`.** It reads the directory: `run.json` if the command ended, otherwise the
lock says whether a supervisor lives (the agent tries to take it and lets go). So a restarted agent
finds what its predecessor started and the core's rule "a container the runtime lists for a desired
replica is adopted, never started twice" does the rest. The agent holds an exclusive lock on the
state directory, so two agents cannot share it (`ZC-E0506`).

A listed container is adopted only if it is the replica's own: it carries the labels `zcube.image`
and `zcube.created` (the revision the replica key was created at; a container with neither label is not the replica's), and a service deleted and
applied again reuses replica ids, so a mismatch means an earlier replica's container. That one is
stopped (asked once, killed after its grace period) and, once it has stopped, the right one starts.

**`lost`.** A container with no `run.json` whose supervisor is gone (the lock is free and the
supervisor had started) is `lost` with `ZC-E0509`. The first time the agent sees that, it kills the
supervisor's process group, so a lost container does not run on, and writes `run.json` with `lost`,
so the verdict is made once and a recycled pid is never signalled twice. A supervisor that never
started within `fake_start_timeout_ms` is the same.

**Faults.** Writing a word into `<state>/faults/<replica id>` ends that replica's container at the
next `list`: `oom` and `pid_limit` kill the command after leaving `forced`, so the supervisor
records the reason; `lost` kills the supervisor and leaves the verdict to the lost rule above. A
fault waits for its replica to exist and run, and is dropped once the container has ended.

**Retention.** The state directory holds at most `fake_containers_max` containers. A start past
that removes the oldest stopped one (`agent_records.remove_container`: spec first, then the other
files and the directory, each removal synced), which is safe: the core records a stopped container's end in
the observed state, and a missing stopped container with a `stopped` record is left alone.

**One record layer.** `FakeRuntime` and the simulator's `SimNode` both persist through
`agent_records` over `AgentState` (`DirState` here, `SimState` in the simulation), so the crash tests
exercise production's write sequence. A start puts `spec.json` before anything runs; a removal
unlinks it first, so a directory without a readable spec is not a container. `scan` skips a
container whose spec is empty, damaged or unreadable (the host refused to read it, or it is too
large), and the others are still listed; ZC-E0502 is for the state directory itself failing (a
refused directory listing included: only a missing one means "no containers"). `SimNode` goes
through the same `classify` as production: a spec whose container never started is `starting` until
`fake_start_timeout_ms` on the simulation's clock, then lost with ZC-E0509; a stop keeps the record
and `run.json`, and `make_room` evicts the oldest stopped one before the next `spec.json` is written. A start
of an image not in the fixtures is refused with `ZBX-E0410` before anything is written, in both paths
(`agent_records.has_image`). `AgentState.remove` of a name ending in `/` removes an empty directory,
durably; that is how `remove_container` finishes. `DirState` fsyncs a file and then its directory on
every put and remove; `SimState` models exactly that (see `agent_state.zig`'s header) and loses the
unsynced tail of an append in a simulated host crash.

## The remembered pair

Every answer of the agent endpoints carries the store's revision and chain hash (docs/api.md,
"The chain pair"). The agent keeps the highest pair in `<state dir>/remembered`
(`{"v":2,"server":"HOST:PORT","revision":N,"hash":"<hex>"}`, written with `put_atomic`: temporary
file, fsync, rename, fsync of the directory), saved after a step when it advanced, at most every
`verified_save_ms`, and once more, whatever the time, when the agent stops cleanly.
It refuses an answer from behind it with `ZC-E0215` and does nothing with it; the step fails and is
retried, so the refusal shows once and the containers run on.

- A state directory without the file (an agent from before C1 slice 10b) starts with nothing
  remembered. A version 1 file (no `server`) is read as saved for an unknown address and its pair
  is kept as it is.
- A pair saved for a different `--server` is not compared: the agent prints one line saying the
  server changed and starts fresh.
- A file that does not parse, or whose `v` is 0 or not a number, stops the start with `ZC-E0216`
  ("not what the agent writes"); a higher `v` says it was written by a newer zcube-agent. A save
  that fails while the agent runs warns once, naming the file's full path, and is tried again.
- A server whose answers say `"verified": false` (a memory store, which starts empty each time)
  is not checked: the agent drops any pair it remembers, keeps none, and says so once on stdout.
- A store recreated at the same address (a new SQLite file, a fresh database) is not told apart
  from a rollback: it is refused with `ZC-E0215`, and the fix is the same `rm`.

After `zcube store accept-rollback --confirm` on the server, `rm '<state dir>/remembered'` and
restart the agent. Recovery is per node: every agent that refused must have its file removed and
be restarted; the server does not tell agents about an accepted rollback (a gap recorded in
docs/DECISIONS.md).

What the agent check guards is what the agent acts on. It does not gate writes to the store: that
is the server's `VerifiedStore`, which refuses every store call once its store went backwards. An
agent's refusal keeps it from starting or stopping containers on the strength of an answer from
behind; the server's keeps the controllers and every write from building on one.

## The peer identity (C2 slice 6a)

At start the agent opens its state directory and loads `peer.key` (an Ed25519 seed, 64 hex
digits, mode 0600; made on the first run), `peer.cred` and `ca.pub`. A file others can read, or
one that does not parse, is `ZC-E0806` and the agent does not start. A stored pair that belongs to
another key, node or CA is ignored and the agent joins again. Before each step the agent calls
`POST /v1/agent/nodes/{node}/credential` if it has no credential or half of its life has passed
(`agent_peer.zig`); the call's timeout stays short of the lease's fence. A failure (an
unreachable server, `ZC-E0807` for a removed node) is shown once and retried every
`peer_join_retry_ms`; it never stops the agent or its containers. Nothing yet uses the credential:
slice 6b's chunk server does.

## The chunk store, the peer server and `fetch` (C2 slice 6b)

With `--registry HOST:PORT` (needs `--images-dir`; `.registry` in the ZON file) the fake runtime
fetches an image that is not in its fixtures, rather than refusing it. Before it runs the command,
the container's supervisor runs `zcube-agent fetch` for the image (`fetch.json`, above), and the
replica reports `starting` while that runs. A failed fetch is a start failure with ZC-E0601, the
text in `fetch.log`.

A `pull.json` the agent cannot publish (unparseable, naming another node or no tree, too big, or
refused by the server) is dropped, counted, and said once per step on the agent's stderr with
ZC-W0504, so a missing /pulls record has a line to find. `ops/zigbox-smoke/guest.sh` prints the
last 2 KB of each agent's `fetch.log`, the container directories and any running `zcube-agent fetch` when any stage fails.

`--images-dir DIR` gives the node a chunk store (`dir_images.zig`: `trees/<digest>` lists and
`chunks/<64 hex>` files, each written whole under a unique temporary name and renamed, each chunk
checked against its BLAKE3 on write and on read). The agent's summary pass reads it on its own
thread; a `DirImages` belongs to one thread, and the peer server gives each connection its own.
`--peer-listen HOST:PORT` (needs `--images-dir`, except with `--runtime zigbox`, where it serves the node's Zigbox store; see below) starts the peer server (`peer_server.zig`): read-only,
CA-authenticated peers only, rate limited (ZC-E0808). The address the node publishes for peers
(`/node-store/<node>.peer`) is `--peer-advertise HOST:PORT` (`.peer_advertise` in the ZON file);
without it, the `--peer-listen` address if that names a host. `--peer-listen 0.0.0.0:P` or `[::]:P`
without `--peer-advertise` is refused at startup with ZC-E0505, because nobody can connect to
`0.0.0.0`. `--address` is only recorded with the node for people to read; it is never connected to.
The server has `peer_handshakes_max` cheap handshake slots and `peer_connections_max` serving
slots, which hold the big buffers and go only to a peer that authenticated: silent strangers
cannot lock honest peers out, and a client that finds every serving slot taken gets status 503
(busy), which the fetch asks again for up to `fetch_busy_wait_ms` (20 s, pauses doubling from
`fetch_busy_sleep_ms` to `fetch_busy_sleep_max_ms`) without a strike against the peer. A fetch
that ends in ZC-E0601 first logs one line per peer asked: how many times it answered busy, a
status other than 200, or nothing.

**Zigbox mode (slice 8).** With `--runtime zigbox` and `--peer-listen`, no `--images-dir` is needed: at start the agent finds the node's Zigbox store (`XDG_DATA_HOME` or `HOME`, as `zigbox pull` does), makes it if it is not there yet, and the peer server serves its trees as bundles (`GET /v1/peer/bundle/<digest>`, docs/peer.md) and its chunks. The server's unused chunk directory is `<state-dir>/peer-chunks`. The agent's summary pass (the trees and chunk filter it reports, which the scheduler's locality uses) reads the same Zigbox store on the agent's thread (`ZigboxImages`), so a tree `pull` or a swarm fetch puts there is reported at the next summary; the store is opened in Zigbox mode whether or not `--peer-listen` is given.

`zcube-agent fetch --node N --state-dir D --images-dir I --digest b3:HEX --registry HOST:PORT
[--server HOST:PORT] [--peer NAME=HOST:PORT]...` (`fetch_cli.zig`) is `fetch_worker.fetch` over the
registry (plain HTTP, `/trees/<digest>`, `/chunks/<hex>`) and the peers. It exits 0 when the tree is
whole in the store and 3 (`exit_external`) with ZC-E0601 when it is not; 1 and 2 are this node's own
setup. The node O5 designates to pull from the registry first does not wait: it notes so in
`fetch.log` and asks the peers at once, so in Zigbox mode it exits 3 with ZC-E0601 and the
supervisor's pull runs (below). A peer is only ever asked when the digest is
the full `b3:` + 64 hex (decisions/2026-11-03-full-digest-untrusted.md).

- `--server HOST:PORT` gives the peers without naming them. The fetch reads
  `/v1/list?prefix=/node-store/` in pages of `discover_page_nodes` (following `continue`), for each node's `peer` address and hex `filter` (keys.md,
  api.md). It leaves out its own node and any node with a bad name, no `peer` or no filter, says
  how many on one line of stderr, and ranks the rest by the chunks their filters claim.
- `--peer NAME=HOST:PORT` adds a peer with a full filter: it is assumed to hold every chunk, and
  the plan strikes it if it lies.
- **Who pulls from the registry first (O5, docs/briefs/c2.md).** With `--server` and a full digest,
  the fetch first reads which nodes fetch the tree: the nodes of `/assigned/<node>/<id>` whose
  replica (`/replicas/<service>/<id>`) has that image. If a peer's `/node-store/` record lists the
  tree whole (`trees`) and has a `peer` address, it goes on as above. Else the node with the
  lowest `fetch_plan.registry_rank(node, tree)` (BLAKE3 of the two; ties to the lower name) goes
  on at once (no peer holds the tree, so it ends at the registry), and every other node re-reads `/node-store/` every
  `fetch_peer_poll_ms` (1 s) for up to `fetch_peer_wait_ms` (30 s) until a peer lists the tree,
  then fetches from peers; after the wait it goes on as it would have without O5. The decision is
  `fetch_plan.start` (core); `fetch.log` says how the wait ended. A node that cannot read the
  lists counts itself the only fetcher and does not wait. The wait is on whole trees, not
  filters, because a Zigbox peer serves a tree only as a bundle of the whole tree
  (decisions/2026-11-05-o5-registry-first.md).

**Not built yet (6b part 3 cut):** the fake registry, `swarm-smoke` and its teeth fault.

Test fault: `<state-dir>/faults/fetch-deadline-ms` (Zigbox runtime) holds a number of
milliseconds, at least 1, that replaces the supervisor's fetch deadline
(`zigbox_fetch_deadline_ms`, 31 minutes) when it is shorter; the fetch is killed at it and the
supervisor falls back to the pull. It is read at each fetch. `zigbox-smoke` uses it.

The fetch runs in a process group of its own, because its store worker (Zigbox's `namespace.run`
child) is a grandchild that neither dies with the fetch nor hears its signals. Whenever the fetch
ends, at its deadline or not, the supervisor sends SIGKILL to the whole group and reaps it (it is
the group's subreaper meanwhile), for at most `zigbox_fetch_kill_wait_ms` (5 s): the pull is
another store writer and starts only once no process of the fetch is left. One that outlives that
wait (in uninterruptible sleep) fails the start with ZC-E0515, and `fetch.log` says so.

Test fault: `<state-dir>/faults/peer-corrupt` makes the peer server flip the first byte of every
chunk it sends, so a client's hash check is exercised. It is read when the agent sets up its peer
server, so restart the agent after creating or removing the file.

### Pull records (C2 slice 7)

`zcube-agent fetch --report FILE` writes a `records.Pull` (keys.md, `/pulls/<node>/<tree>`) to
`FILE.tmp` and renames it, when the pull succeeds: the bytes by source come from the fetch
worker's `Report` (`registry_bytes`, `peer_bytes` by peer index, `cached_bytes`, `struck_peers`).
The runtime adapter passes `--report <container dir>/pull.json`. On each `reconcile` the agent
(`publish_pulls`, after the replica pass, so statistics never hold replicas back) lists
`containers/`, reads each `pull.json` and writes
at most `pulls_per_step_max` (8) of them through the tenure-checked pulls endpoint, removing
each file once it is stored. A record that does not parse, or names another node, is dropped; a
server without the endpoint (`ZC-E0504`) gets the file dropped; a failed tenure compare begins a
fence like any other agent write and keeps the file for the next tenure. A failed fetch leaves
no record.

## Runs (B1 slice 4)

A job is a run: container `<job>-job`, labels `zcube.replica` (the run id) and `zcube.job`. `src/agent_jobs.zig`
is one pass of `reconcile`, after the replicas. It wants a run when the node holds its
`/assigned/<node>/<run>`; the epoch is that assignment's `mod_revision`.

1. **Claim, then start.** The agent writes the start record `jobs/<run>.json` (phase `claiming`, the
   `boot_id`, `deadline_mono_ms`) and then one transaction: the tenure, the run record's revision, the
   assignment's epoch, and `/job-observed/<node>/<name>` absent. Only when it applies does it fetch
   the input (digest checked), set phase `claimed` and call `Runtime.start`. A refused claim starts
   nothing. The server's `{applied:false}` is a result, not an error.
2. **A run is started at most once.** A claim in the store without a start record, or a `claimed`
   record whose container is gone, ends the run `lost`; the agent never starts it again. A record
   still `claiming` after a restart claims again (the compare says whether it won).
3. **The deadline** is `deadline_mono_ms` on the boot clock, written before the start and compared
   only under the same `boot_id`; after a reboot the container is gone and the run ends `lost`, not
   `deadline`. The agent enforces it without the server: every step, before any call to
   `zcube-server`, it lists the runtime and reads the start records (`enforce_deadlines`); a run
   past its deadline gets `stop_cause` `deadline`, TERM, and the kill when its grace ends. The next
   deadline or kill is a wake, and every call and backoff is capped at it as at the fence, so a cut
   link, a hung call or a run whose report keeps failing delays no run's stop. The pass reports the
   ending once the server answers.
4. **`stop_cause`** (`cancel`, `deadline`, `fence`, `not_started`) is written to the start record
   before the container is signalled and reported with the exit. An exit the agent saw first
   carries none. A fence under a replaced tenure is reported under the next tenure, once it holds.
5. **Adoption.** After `kill -9` the new agent lists the runtime, reads the start records, and adopts
   a `claimed` run without a second start.

The fake runtime's `faults/<name>` files (`oom`, `pid_limit`, `lost`) work for a run by its id.

## What survives what

| Event | Containers | The agent's work |
| --- | --- | --- |
| agent stopped or killed | keep running | a new agent adopts them |
| server down or restarted | keep running | the agent backs off, reports `ZC-E0503` once, carries on when it returns |
| the lease cannot be kept (the server is away, or the lease is gone) | stopped at `s + ttl − fence_margin` (the agent fences itself; `s` is the send time of the last acknowledged keepalive, on `CLOCK_BOOTTIME`), or at once if the server says the lease is gone | grants a new lease, registers again empty under a new tenure, prints `ZC-W0501` |
| an observed write is refused (`ZC-E0510`: its tenure was replaced) | stopped at once | as above |
| a command is killed | the supervisor records it | reported; the controller replaces the replica |
| a supervisor is killed | the command is killed by the agent | reported `lost` with `ZC-E0509`; replaced |
| the host restarts | none | everything is `lost`; replaced; a kept lease of another boot (`/proc/sys/kernel/random/boot_id` in `lease.json`) fences |
| the agent dies while fencing | keep fencing: the kept `fencing` flag makes the next agent finish the fence by the first kill time | as above |

## What the real-process model showed about `Runtime`

The contract is approved and I changed nothing in it. These are gaps between it and a runtime with
real processes, for the owner and for the Zigbox adapter:

1. **`stop` cannot wait out a long grace in a single-threaded agent.** The contract says `stop`
   returns once the container has stopped. The agent asks with `stop_grace_ms` (5 s), and the
   agent's lease is renewed in the same thread every third of its ttl (3.3 s of 10 s, `fencing.renew_after_ms`). Three
   containers that ignore `SIGTERM` would starve the lease. `FakeRuntime.stop` sends the polite
   signal and waits at most `stop_wait_ms` (500 ms); a longer grace returns with the container
   still running, and the core's pending-stop logic asks again with a grace of 0 to kill. The
   simulated runtime departs the same way, which `core.md` records. **Recommendation:** document
   that `stop` may return early, and that the caller checks `inspect`; the adapter should do the
   same, or the agent must run stops off the thread that holds the lease.
   **Done for the fence (C2 slice 3, P2):** `Runtime.signal(handle, number)` takes TERM or KILL
   and returns at once. The fence signals TERM to every container in its first step, then looks
   at `list` every `fence_poll_ms` and signals KILL to what is left at the kill time, so N
   containers cost one `fence_stop_ms`, not N waits of `stop_wait_ms`. The reconcile loop's own
   stops still use `stop` and the pending-stop logic.
2. **The runtime does not report when a container started.** `Listing` has no start time, so the
   agent's `started_at_ms` is when it started or first saw the container. `FakeRuntime` knows it
   (`spec.json`), and Zigbox's run record could carry it. Adding a field to `Listing` is the
   contract change; it would make a replica's age survive a lost observed record.
3. **`start` is two things.** The supervisor can fail to start the command (not found, not
   executable) after `start` has been accepted. `FakeRuntime` waits for the supervisor to say, so
   `start` still returns `StartOutcome.failed` (`ZC-E0508`, blamed on the user, so the replica is
   held); a real adapter must wait for `zbx`'s run record in the same way, or the failure arrives
   as `Status.stopped(start_failed)` on a later `list`, which the core also handles.
4. **`lost` needs a verdict that is made once.** A runtime that reports `lost` on every `list`
   until something changes would re-kill a recycled pid. `FakeRuntime` records the verdict. The
   contract is silent on whether `lost` is sticky.
5. **Events are polled.** `FakeRuntime.events` scans the directory. A real adapter could use
   `pidfd` or inotify on the run records. The agent loop does not depend on them: it checks them
   with a timeout of 0 between 250 ms long polls, so a command that ends is noticed within about
   that long.
6. **`env` and `limits` are not applied.** A plain host process: `env` is passed, `limits` are
   recorded and ignored, as the contract review expected until Zigbox M2.
7. **Zombies.** An agent that started a supervisor must collect it (`reap`), and one that was
   started after its predecessor died cannot (the supervisors were reparented to init, which in
   some containers does not reap). `zcube-agent` is not PID 1 and cannot fix that; the smoke test
   counts live supervisors by state, not by `kill(pid, 0)`, for this reason.

## The Zigbox runtime (`--runtime zigbox`)

`zcube-agent --runtime zigbox` runs containers with Zigbox (`src/zigbox_runtime.zig`); `fake` is
the default and what every test and demo uses. The shape is the fake runtime's: **one supervisor
per container**, `zcube-agent supervise-zigbox <state>/zigbox/<name>`
(`src/zigbox_supervisor.zig`), so stopping the agent leaves the containers running and a restart
adopts them (`list` is `zigbox.lifecycle.list` plus `adopt`). The agent never holds a Zigbox
`Handle`.

- **Launch directory** (`zigbox_launch.zig`): `spec.json` (written first by the agent), `lock`
  (held by the supervisor while it lives), `failed.json` (Zigbox's diagnostic if it could not
  start). A pull can take minutes before Zigbox has any record, so the replica is `starting`
  while the lock is held and no record of this launch exists; `lost` if the supervisor is gone and
  left nothing; `start_failed` with `failed.json`. A Zigbox record older than the launch is an
  earlier container of the same name and is ignored: a record belongs to a launch only if it was
  begun at or after the launch *and* its `supervisor` is the pid in the launch directory's
  `supervisor.pid` (the time has one-second resolution, so a relaunch within the second would
  otherwise adopt the old record). A record with pid 0 is Zigbox's start window, before the
  container exists: it is `starting`, never `running`, and `stop` kills the supervisor, never
  pid 0; if the supervisor dies there the record reads `lost`. Killing a supervisor kills its
  whole session (it leads one of its own): SIGKILL to its group and then to every process whose
  session is the supervisor's, read from `/proc` (`process_session.zig`), because the swarm fetch
  and its store worker are in that session but in a group of their own.
- **Images** (`zigbox_image.zig`): the supervisor tries `zigbox.start` with the locked tree
  digest; on ZBX-E0410 (tree not in the store) and a known reference it pulls once, checks the
  tree it got is the locked one (ZC-E0511 if not) and starts again. The locked digest must be
  the full `b3:` plus 64 lowercase hex digits (an abbreviated or unprefixed one is refused at
  apply, naming the form), since the check is an exact compare. The pull passes the mirrors in
  `ZBX_REGISTRY_MIRRORS` of the *agent's* environment (Zigbox's own variable, same format; at most
  4096 bytes) to Zigbox's `pull`; unset means none. The supervisor runs on a single-threaded
  `std.Io` and checks `Threads: 1` in `/proc/self/status` before start or pull (Zigbox makes
  namespaces, which the kernel allows a single-threaded process only); otherwise ZC-B0002. `--images FILE` for this
  runtime is `.{ .images = .{ .{ .digest = "b3:...", .reference = "ghcr.io/o/r@sha256:..." } } }`;
  the digest-only form is the fake runtime's. **Deprecated** for this runtime: a service names the
  reference it is pulled from in `source` (docs/keys.md), which travels in the replica and the
  `Spec`, and wins over this file; the file is the fallback for a service without one (the agent
  says so on stderr at start). With neither, nothing is pulled.
- **Stop**: SIGTERM and a wait of at most 500 ms when there is a grace, SIGKILL and the same
  single wait of at most 500 ms when there is none; the caller asks again as with the fake runtime.
- **Signal** (the fence's call): the same delivery as `stop`, TERM through `lifecycle.signal`
  (Zigbox sends SIGKILL in its place for a PID 1 with no handler) and KILL through the host, and
  no wait at all. Only TERM and KILL are accepted. A container that is still starting has its
  supervisor killed, as with `stop`; a stopped one is left alone.
- **Limits** are Zigbox's (`zigbox_map.zig` mirrors its bounds; apply refuses more, ZC-E0514).
  CPU, memory and pids limits need the user's systemd bus; Zigbox's ZBX-E0307 (no bus) is
  reported as ZC-E0512 with the fix.
- **Preflight**: the agent refuses a host that is not Linux or cannot read Zigbox's run records
  (ZC-E0513). Zigbox's doctor is not exported, so the rest is named by Zigbox at the first start.
- **Tests**: the lifecycle calls run over Zigbox's `HostSim` (`zigbox_runtime.zig`); the image
  decisions are table tests (`zigbox_image.zig`). `start` and the supervisor need a real host:
  `ZCUBE_REAL_HOST=1 zig build zigbox-smoke` (QEMU guest through Zigbox's `zigbox_vm` module).
  It runs `ops/zigbox-smoke/guest.sh` stage by stage (setup, replicas with cgroup limits and
  no network but `lo`, `kill -9`, agent restart, `oom`, ZC-E0511 and ZBX-E0410 refusals, a
  service removed during its pull); `docs/demos/c2.md` lists the assertions and the cuts
  (`pid_limit`: a service cannot set `pids`). It is a check, never `demo-c2`.

## Known limits

- **A whole call is bounded, connect included; Linux only.** The standard library's threaded `Io`
  panics if `connect` is given a timeout on POSIX, so `agent_http.zig` opens a non-blocking socket
  itself (`std.os.linux`), `poll`s it for the connection until the call's end, and hands the
  connected socket back to `Io` in blocking mode. One deadline, the hold plus
  `agent_io_timeout_ms`, covers connect, send and every read; the client `poll`s before each read.
  While the agent holds a lease the deadline is cut to the fence (`fence_at`), and to a run's next
  deadline or kill: no call waits past it, and a call that would start after it is not made
  (`ZC-E0503`; the fence, or the run's stop, goes on). It does not use a receive timeout
  on the socket, which makes the standard library's reader panic when it fires; the agent died
  with `ZC-B0001` whenever a server held a request that long (a store outage does), which slice 6c
  found. A request is small and is written at once, so a write has no timeout.
- **The long poll is a quarter of a second.** The agent waits on the server for
  `agent_watch_slice_ms` at a time, so that it can look at the local runtime between polls, which
  makes about four requests a second per idle agent. A thread for each, or a runtime that can be
  waited on beside a socket, would make it one.
- **Every replica change wakes every agent** (C0 has one node; C1 narrows the watched prefix to the
  node's `/assigned/` index, see api.md).
- **No auth.** The agent endpoints return `env` values and write the store, like `POST /v1/apply`.
