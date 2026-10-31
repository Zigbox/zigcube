# The node agent

**Status: C0 slice 6a (2026-10-27).** What `zcube-agent` is made of, how `FakeRuntime` runs real
processes under the supervisor model, what survives what, and what building it showed about the
`Runtime` contract. The agent's endpoints are in [api.md](api.md) ("Agent endpoints (slice 6a)");
the decision-making is `src/agent.zig`, described in [core.md](core.md).

## The pieces

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
digest is `start_failed` with the placeholder `ZBX-E0501` ([runtime-codes.md](runtime-codes.md)).
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
of an image not in the fixtures is refused with `ZBX-E0501` before anything is written, in both paths
(`agent_records.has_image`). `AgentState.remove` of a name ending in `/` removes an empty directory,
durably; that is how `remove_container` finishes. `DirState` fsyncs a file and then its directory on
every put and remove; `SimState` models exactly that (see `agent_state.zig`'s header) and loses the
unsynced tail of an append in a simulated host crash.

## What survives what

| Event | Containers | The agent's work |
| --- | --- | --- |
| agent stopped or killed | keep running | a new agent adopts them |
| server down or restarted | keep running | the agent backs off, reports `ZC-E0503` once, carries on when it returns |
| lease lost (the server was away longer than the ttl) | keep running (C0; C1 stops them) | grants a new lease, registers again, prints `ZC-W0501` |
| a command is killed | the supervisor records it | reported; the controller replaces the replica |
| a supervisor is killed | the command is killed by the agent | reported `lost` with `ZC-E0509`; replaced |
| the host restarts | none | everything is `lost`; replaced |

## What the real-process model showed about `Runtime`

The contract is approved and I changed nothing in it. These are gaps between it and a runtime with
real processes, for the owner and for the Zigbox adapter:

1. **`stop` cannot wait out a long grace in a single-threaded agent.** The contract says `stop`
   returns once the container has stopped. The agent asks with `stop_grace_ms` (5 s), and the
   agent's lease is renewed in the same thread every third of its ttl (3.3 s of 10 s). Three
   containers that ignore `SIGTERM` would starve the lease. `FakeRuntime.stop` sends the polite
   signal and waits at most `stop_wait_ms` (500 ms); a longer grace returns with the container
   still running, and the core's pending-stop logic asks again with a grace of 0 to kill. The
   simulated runtime departs the same way, which `core.md` records. **Recommendation:** document
   that `stop` may return early, and that the caller checks `inspect`; the adapter should do the
   same, or the agent must run stops off the thread that holds the lease.
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

## Known limits

- **Connecting has no timeout.** The standard library's threaded `Io` panics if `connect` is given
  one on POSIX, and a socket option can only be set after the socket exists. A server that is down
  refuses at once (the case on one network); a host that drops packets makes the agent wait as long
  as the kernel does. A read waits at most `agent_io_timeout_ms` (plus a long poll's own hold) for
  the next piece of a reply: the client `poll`s before each read. It does not use a receive timeout
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
