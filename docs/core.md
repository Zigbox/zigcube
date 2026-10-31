# The control-plane core

**Status: C0 slice 5a (2026-10-26).** What the core is, the step model every controller follows,
how a shell drives it, and what the simulation proves and does not. The rule that keeps it pure
is in [wasm.md](wasm.md); the key layout and records are in [keys.md](keys.md); the API in
[api.md](api.md).

## What is in it

Everything below is listed in `src/core.zig`, compiles for `wasm32-freestanding` and has no
thread, socket, file, libc, `std.Io` value, real clock, source of randomness or blocking call.

| Module | What it is |
| --- | --- |
| `records.zig` | The records of keys.md as types, their JSON, the key builders, decision ids |
| `controller.zig` | `Context`, `Wakeup`, `Batch`, the snapshot reader, the one way to write a decision |
| `replica_controller.zig` | The service and replica controller, with the C0 placement |
| `retention.zig` | Decision retention, a page of the index at a time |
| `apply.zig` | What the API writes on apply and delete (generation rules, change summary) |
| `agent.zig` | The node agent's reconcile step |
| `agent_api.zig`, `agent_client.zig` | The server's side of the agent endpoints, and `Store` over them on a `Transport` |
| `agent_loop.zig` | The agent's loop policy as a state machine over virtual time |
| `agent_state.zig` | What the agent persists, behind `AgentState`; `SimState` models what fsynced files guarantee, with `arm_crash` (a crash at a write point) and `crash_now` (between calls) |
| `agent_records.zig` | The container records and adoption rules, over `AgentState`; shared by `FakeRuntime` and `sim_node.zig` |
| `sim_net.zig` | The network between agents and server: drop, delay, duplicate, reorder, one-way partitions; parked requests arrive when the cluster calls `tick` with the clock |
| `sim_clock.zig` | A node's monotonic clock: an offset from the server's, a bounded rate error, jumps forward (a suspend), never backwards |
| `sim_store.zig` | `AckLossStore`: the lost acknowledgement (a transaction that commits and returns an error) over the memory store, and a switch for outages |
| `sim_node.zig` | One simulated node: a `SimRuntime` and a `SimState` joined by `agent_records` |
| `why.zig` | `zcube why`: subject to causal chain, structured steps, and their text |
| `api.zig` | The read-only endpoints of api.md, bytes to bytes |
| `runtime_codes.zig` | The placeholder `ZBX-` codes ([runtime-codes.md](runtime-codes.md)) |
| `sim_runtime.zig` | `Runtime` implemented in the core, deterministic, with faults |
| `sim_world.zig` | The smallest honest shell: server, agent, store, runtime on virtual time |
| `sim_c0.zig` | The C0 simulation and its fuzz variant |
| `sim_cluster.zig` | The cluster simulation: N agents, a network, a store, the controllers, one seed ([below](#the-cluster-simulation)) |

## The step model

A controller is `reconcile(ctx) -> Wakeup`. It reads what it needs, does what is due, writes each
action together with its decision record in one transaction, and returns. It never waits: not on
a `Watch`, not on `Runtime.events`, not on `Runtime.stop`.

```zig
pub const Wakeup = struct {
    at_ms: u64,                    // run again no later than this (on the Clock's scale)
    prefixes: []const []const u8,  // or sooner, if a key under one of these changes
    acted: u32,                    // transactions this step committed; 0 when converged
};
```

`Context` holds the `Store`, the `Clock`, an arena (`request_arena_bytes_max`, freed whole when
the step ends) and a `*Diag`. The agent's context also holds the `Runtime`. A failed step returns
an error with a diagnostic in `ctx.diag`; the shell decides when to retry.

Four rules make this work:

- **Level-triggered and idempotent.** A step compares desired state with observed state and
  acts on the difference; on a converged system it writes nothing (`acted == 0`, tested). It does
  not matter which event woke it, or whether one was lost.
- **Partial progress is normal.** A transaction touches at most four replicas, so a change to a
  service of 100 replicas takes several steps. The step returns `at_ms = now`; the next call
  carries on from what the store then says. A transaction whose compare fails (the state moved
  under the plan) writes nothing, and the next step plans again.
- **Whatever cannot finish now becomes state the next step checks.** The agent asks for a stop
  once, remembers the container's name and the end of its grace period, and on a later step kills
  what still runs. A held replica is a decision in the store, not a flag in memory.
- **Identity is a parameter.** Decision ids use the time (the `Clock`, which must be Unix
  milliseconds for `at_ms` to mean what keys.md says), a controller instance number from the shell
  and a counter. A restarted server takes a new instance number.

## What the shell does

The shell is whatever calls the steps: `zcube-server` and `zcube-agent`, `sim_world.zig`, and
later the browser. For each side it loops:

1. wait until `Wakeup.at_ms`, or a change under `Wakeup.prefixes` (a `Watch` with a timeout; the
   memory store and the simulation compare revisions instead), whichever is first;
2. build a `Context` with a fresh arena and call `reconcile`;
3. on an error, render the diagnostic, wait a backoff and retry.

The shell also owns what the core must not: calling `Store.expire_leases` and `Store.compact` on
timers (the world does both), the real clock, threads, HTTP, and the long-poll wait of
`GET /v1/watch` (below).

**API handlers.** `Api.handle(ctx, Request) -> Response`: method, path, query and the client's
request id in; status, request id, JSON body out. A failure is a DIAGNOSTICS diagnostic whose
status the blame decides. Watch answers what is ready with a bookmark; if nothing is ready and the
client asked to wait, `Response.hold_ms` and `hold_prefixes` tell the shell it may hold the reply
until a key under one of the prefixes changes, then call `handle` again with the same request.

## What the controller decides

| Situation | Decisions (subject) | Cause |
| --- | --- | --- |
| fewer replicas than wanted | `scale_up` (service), `create_replica`, `place_replica` (replica) | `desired` |
| more than wanted | `scale_down` (service), `stop_replica` (replica) | `desired` |
| container ended, or lost | `delete_replica` or `mark_replica_lost` (replica), `replace_replica` (service) | `observed`, with the diagnostic copied in |
| start failed through the user's fault | `hold_failed_replica` (service), once per observed record | `observed` |
| replica behind the service's `generation` | `replace_replica` (service), `stop_replica` | `desired` |
| service deleted | `scale_down` (the gone service), `stop_replica` | `desired` |

A replica-count change does not bump `generation`; a failed start is held, not retried; a held
replica is replaced when the service changes. Placement is the C0 scheduler: a node whose declared
capacity fits the replica's resolved requests (its limits, else 250m CPU and 128 MiB, which the
placing decision says), the fewest replicas of the service first. A replica no node fits waits,
unplaced, with no decision; `why` says "waiting for a node".

## What the simulation proves

`zig build sim-c0 [-Dseed=N] [-Dops=N]` runs `sim_c0.zig` natively and as WebAssembly, for one
seed, and compares the two reports byte for byte. **It is a simulation, not `demo-c0`.** It runs
the core against a memory store and a simulated runtime on virtual time, through HANDOFF's C0
steps (apply 3, kill one, scale to 5 and to 2, apply `broken`, `why`, the store down, restarts),
asserting each outcome, including the rendered `zcube why service broken` chain.

It proves that the core makes the decisions the demo script asks for, deterministically, with
every fault under test control; that the two cores cooperate through the store alone; that native
and WASM builds agree (the report ends with a hash of the whole store); and, with the fuzz
variant, that under random applies, deletes, runtime faults, store outages that begin mid-step,
restarts and compaction:

- the runtime never holds more running containers than services want for more than 30 s of store
  uptime;
- every decision has a reason and a cause; a cause that names a decision names one that exists,
  unless retention dropped decisions (a counter says whether it did);
- `why` terminates for every service and replica, and ends in a cause, not a decision;
- once healed, every service has the replicas it asked for (held ones for a broken image) and the
  runtime holds nothing else.

It does not prove: real processes and `kill -9`, Postgres or SQLite (the stores' conformance suite
covers the store contract), the `zcube` command, real time, or anything about `zbx`. A passing
simulation is never a passed demo. It also cannot show what a model of the runtime leaves out:
the simulated runtime stops a container at once unless told to be slow (see below), and ends a
container only through the faults it has.

Seeds: `-Dseed=N` (default 1). A fuzz failure prints its seed and the virtual time; `zig build
sim-c0-exe` installs the native runner for loops over many seeds (`sim_c0 <seed> fuzz <ops>`, best
built with `-Doptimize=ReleaseSafe`).

## Where the core is lazier or narrower than the contracts

- **`Runtime.stop` returns early in the simulation** when a container ignores the polite stop
  (`slow_stop`). The contract says it returns once the container has stopped; a runtime in
  virtual time cannot wait. The agent never relies on a stop having completed, so a blocking
  adapter is also correct for it. This is the one place the simulated runtime departs.
- **The runtime does not report when a container started**, so the agent's `started_at_ms` is
  the time it started or first saw it (kept across re-adoption if a record exists). Zigbox's
  `Listing` could carry it.
- **Nobody writes `lease_expired` yet.** Lost-node detection is C1. `why` renders the cause (a
  test writes one by hand) and the node's registration is on a lease the agent keeps alive.
- **An agent that loses its lease re-registers and keeps its workloads running.** Stopping them
  (so a replica never runs twice) is C1's acceptance criterion.
- **Retention runs in the controller's step, a few pages at a time, not in the transaction that
  writes a decision** as keys.md words it: a count needs a list.
- **The API's write endpoints** arrived in slice 5b as a proposal (api.md, "Writes"): `POST
  /v1/apply` and `DELETE /v1/services/{name}`, `apply.zig` behind a route. `apply` now returns the
  decision id and the change summary, and `plan` is a dry run.

## What the shell revealed about the step model (C0 slice 5b)

`zcube-server` is the first shell that drives the core on real threads, a real clock and real
stores (`src/server*.zig`). The model held: the controller, the agent's step and the handlers were
driven as they were, and the same handlers answer HTTP and the browser. Two small changes came out
of it (`Request.hold`, an atomic request counter), and the rest of what it taught is below:

- **`Wakeup.prefixes` is several prefixes; `Store.watch` takes one.** The driver opens one watch on
  every key and filters locally against the prefixes. That also delivers every decision write, which
  the controller ignores; on Postgres it keeps the cost to one connection, where a watch per prefix
  would be four.
- **A step that acted always wakes itself.** Its own writes are under the prefixes it named, so the
  next wait ends at once and the following step finds `acted == 0`. It costs one extra snapshot read
  per acting step. It is harmless and honest; if snapshots grow, `Wakeup` could carry "ignore up to
  revision R" for the step's own writes.
- **"Call `handle` again with the same request" was not enough for a held watch.** The same request
  would ask to be held again. `Request.hold` (default true) is the shell's way to say "answer with
  what is ready and nothing more"; the first, empty answer is what a timed-out hold sends. The
  shell opens its store watch from the revision it read *before* calling `handle`, so a change
  between the handler's look and the shell's wait cannot be missed.
- **`Api.handle` needed `*Api`, which made it serial.** Only the request counter and the decision
  source are mutable: the counter is atomic now, so reads run side by side, and writes (which move
  the source) take a mutex in the shell.
- **The memory store does not wait.** `Watch.next(timeout)` returns at once on it, so every loop that
  waits on a watch (the driver, a held request) naps `server_poll_ms` when an empty batch comes back
  early. On SQLite and Postgres the call itself waits. The memory store also needs a mutex in a
  threaded shell (`server_store.zig`, `Locked`).
- **Identity is the shell's.** The controller's instance number is derived from the start time so a
  restarted server takes a new one; the API's source keeps instance 0, so the two never share a
  decision id.
- **Failure shows once.** A store that goes down fails every step; the driver prints the diagnostic
  when the code changes or every 30 s, backs off 250 ms doubling to 5 s, drops and reopens its
  watch, and prints one line when it recovers. Nothing in the core had to know.
- **The arena limit is real.** Each request and each step has a `BoundedArena` of
  `request_arena_bytes_max`; the core already reports a full arena as `ZC-E0207`. With 64
  connections that is a worst case of 1 GiB of address space, touched only if requests are that
  large.
- **`SO_REUSEADDR`, without `SO_REUSEPORT`** (`server_listen.zig`). The standard library ties
  `SO_REUSEADDR` to `SO_REUSEPORT` (`Io.net.IpAddress.ListenOptions`): with both, a second server on
  the same port starts without complaint. Without `SO_REUSEADDR`, a server cannot listen on its port
  for a minute after it closed a connection first (an idle client, a reply that ends the connection,
  a connection open when it stops: the connection sits in `TIME_WAIT`), so a restart was `ZC-E0107`.
  So on Linux the listening socket is made by hand with `SO_REUSEADDR` alone: a restart works at
  once, and a second live server on the same port is still refused loudly (`SO_REUSEADDR` does not
  allow a port with an active listener; `server_test.zig` checks both). Elsewhere the strict listen
  of the standard library is used, with the old limit.
  **Slices 6a and 6c found this from the client side first**: the agent, then the `zcube` command
  (which sent `Connection: close` and read to the end), made the server close first. Both clients now
  close first, which is still good manners, but the server no longer depends on it; review showed that
  an idle connection, a browser or `curl` could still block a restart.

## The cluster simulator's pieces so far (C1 slice 2b)

- **Crash model.** `SimState` models what the agent's files guarantee. A `put_atomic` is whole after
  any crash and durable once it returns (temporary file and directory both fsynced); a `remove` is
  durable once it returns; an `append` guarantees nothing, and a simulated host crash can drop the
  unsynced tail of any file. `arm_crash(n, kind)` crashes at the nth write point of the next calls;
  `crash_now(kind)` crashes between two calls, which a write point cannot express (the step
  boundaries). After a crash every call fails with `Crashed` until `restart`.
- **Delivery by the clock.** `SimNet` parks a reordered request with a delivery time. The cluster
  calls `SimNet.tick(now_ms)` after every advance of the clock, and that, not a later call on the
  link, delivers what is due: so a stale write can land after the server's own clock has moved on.
- **Records.** `sim_node.zig` runs the same `agent_records` code as `FakeRuntime`; an unknown image
  is refused and writes nothing in both. `scan` skips a container whose spec the host cannot read.

## The cluster simulation

`zig build sim-cluster` (`src/sim_cluster.zig`, run by `sim_cluster_main.zig` natively and by
`wasm_core.zig` as WebAssembly) is `sim-c0` for a fleet: the server's controllers and API, up to
four nodes, each with the real `Agent`, the real `agent_loop` policy and `agent_client` over
`SimNet`, a clock of its own, a `SimNode` (containers that outlive the agent, agent files that a
crash leaves as the files would be), and the memory store behind a lost-acknowledgement layer. One
seed fixes everything; the run's report ends in a hash of the whole store and every node's runtime,
so one seed twice gives one hash and the native and WASM reports agree byte for byte. `sim_world.zig`
and `sim_c0.zig` are untouched: `sim-c0`'s report is what it was.

**The swarm.** The seed picks the node count (1 to 4), the rate of every fault below (zero a
quarter of the time, so some worlds have no partitions and some no crashes) and the weights of the
workload, and the run prints them first. A report therefore says which world it ran in.

**The faults**, each at the seed's rate and kept low enough that a cluster still works while faulty
(the run fails if the fault phase got too little agent work done):

| Layer | Faults |
| --- | --- |
| Network, per link and direction | drop a request, drop a reply (after the server committed: the agent sees a failure for a write that happened, the case the simulator makes common), delay, duplicate, reorder (a parked request lands when the clock reaches it, even after the world moved on), one-way and two-way partitions that heal |
| Store | a lost acknowledgement (commit, then an error to the caller), outages |
| Server | restarts (a new instance number, memory gone, store kept) |
| Agent | crash at any step boundary or at any write point of its files (`SimState`: a put that is renamed into place is whole or absent, an append can lose its tail), restart that adopts by replica id |
| Node clock | a rate error up to the swarm's `clock_rate_ppm_max`, an offset, a suspend that jumps the node's `CLOCK_BOOTTIME`-like clock forward |
| Runtime | `random_fault` of `SimRuntime`: an oom, a pid limit, a lost container, a crash exit |
| Workload | apply, scale, delete, a broken image, the passage of time |

**What it proves.** Each virtual second and after each operation (during the heal as well): `sim-c0`'s
invariants read over the whole store (every decision has a reason and a cause that exists; `why`
terminates and ends in a cause); no container lives longer than 120 s of reachable time on a node
that no replica assigns it to; a placed replica of a good image is running on its node within 24 s
of reachable, working time; no node's agent works in a busy loop (200 steps per minute of uptime)
and the cluster does not starve (5 successful agent steps per minute of uptime over all nodes
together, checked when they were up 120 s in the fault phase). With
**liveness mode**, the default, the faults run for the first `H` operations, `H` drawn from the seed
alone between half the run and all of it, then every fault is off for the rest of the operations,
and 240 s of virtual time after the last one every service has the replicas it asked for (held ones
for a broken image), each in the image and generation it asked for, and no node runs anything
else. `-Dliveness=false` keeps the faults to the end and checks only safety.

**Duplicates are counted, not failed.** Without leases and fencing (slice 6) a partition can leave a
replica running on two nodes. The report prints the replica-seconds, with the note that the number
is counted and not a pass; slice 6 turns the counter into a failure. Nobody should read it as a pass.

**What it does not prove.** Real processes, `kill -9` and real supervisors (`agent-smoke` and
`demo-c0` start those); Postgres and SQLite (the conformance suite covers the store contract; the
simulator's store is the memory store, and a lost acknowledgement is what a real database's
connection loss after commit would look like, not a model of its failure modes); the real `zbx`
(the runtime is `SimRuntime`, which stops at once unless told to be slow); the `zcube` command;
real time and the real OS clock; TCP and HTTP framing (the network carries the bytes of
`agent_api`, and the transport faults are the ones above); a disk that corrupts rather than loses a
tail; the scheduler and node controller (slice 3: placement is C0's). A bug in any of those, and
anything the models leave out, can pass every seed. A passing simulation is never a passed demo.

**Teeth.** A simulator that never fails proves nothing, so the agent has one test-only fault:
`agent.fault_ignore_stop`, "the agent ignores every order to stop a container". It is a constant
that a program's root file switches on by declaring `agent_teeth_ignore_stop`; the only root that
does is `src/sim_teeth_main.zig`, which only `zig build sim-teeth` compiles. The shipped binaries
have other roots, and `zcube_agent.zig` asserts at compile time that it is off, as a unit test
does for the test build. `zig build sim-teeth` runs that simulator over seeds 1 to 10 at 100
operations and passes only if a seed fails: it fails at seed 1 (20 of 20 seeds fail in a first
trial) with "a container runs that no replica assigns to its node". `check` runs it. It builds in
Debug because that takes 7 s where ReleaseSafe takes 50.

**Commands.**

```
zig build sim-cluster [-Dseed=N] [-Dops=N] [-Dnodes=N] [-Dliveness=false]
zig build -Doptimize=ReleaseSafe sim-cluster-exe
zig-out/bin/sim_cluster <seed> <ops> [<nodes>] [--liveness=false] [--heal-at=H]
zig-out/bin/sim_cluster --seeds A..B <ops> [<nodes>] [--liveness=false] [--shrink]
```

The first runs one seed natively and as WASM and compares. The range form prints a line per failing
seed (`seed N: FAILED: <what>`) and its replay command, then a count; the exit code is 1 if any
failed. **Replay:** the printed command reruns exactly that seed; its `--heal-at` is the heal point
the run printed. **Shrink:** `--shrink` bisects the operations of each failing seed to the smallest
count that fails with the same symptom, holding `H` where the full run had it (it is drawn from the
operation count, so a shorter run would otherwise heal elsewhere); the printed replay of the shrunk
count carries `--heal-at`, so it is the same run, cut short. It assumes that more operations keep
failing, and checks only that its answer fails and one fewer does not fail the same way, so on a
failure that comes and goes it may not be the smallest. `zig build sim-teeth-exe` installs the
fault-on runner (`zig-out/bin/sim_teeth`, same flags) to try shrinking on the teeth fault. A run at
100 operations takes about 0.7 s natively in ReleaseSafe.

`zig build check` runs `sim-cluster` on a fresh seed (printed as `sim-cluster: seed N`) at 40
operations, native against WASM, and `sim-teeth`.
