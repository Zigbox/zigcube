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
| `why.zig` | `zcube why`: subject to causal chain, structured steps, and their text |
| `api.zig` | The read-only endpoints of api.md, bytes to bytes |
| `runtime_codes.zig` | The placeholder `ZBX-` codes ([runtime-codes.md](runtime-codes.md)) |
| `sim_runtime.zig` | `Runtime` implemented in the core, deterministic, with faults |
| `sim_world.zig` | The smallest honest shell: server, agent, store, runtime on virtual time |
| `sim_c0.zig` | The C0 simulation and its fuzz variant |

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
- **Known limit: `reuse_address`.** The standard library ties `SO_REUSEADDR` to `SO_REUSEPORT`
  (`Io.net.IpAddress.ListenOptions`). With it, a second server on the same port starts without
  complaint; without it, a restart can find the port in `TIME_WAIT` for a short while after a
  server that closed connections first. The server does not set it: a second server fails loudly
  with `ZC-E0107`.
  **Slice 6a found this was not "a short while".** A connection the server closes first keeps the
  port in `TIME_WAIT` for a minute, and the server closed first when it stopped while answering a
  request: `zcube-agent` holds a long poll all the time, so every restart hit it. A stopping
  server now waits for the client to close a connection it is done with (`server_http.zig`,
  `wait_for_client`), so the client sends the first FIN, and the agent's client closes as soon as
  it has read its reply. A browser tab with a kept-alive connection still has the server close
  first, after `server_stop_ms`.
