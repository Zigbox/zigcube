# 2026-11-13: B4 slice 3, certificates in the cluster simulation

Brief: docs/briefs/b4.md, "Slices", item 3. Code: `src/sim_certs.zig` and its wiring in
`src/sim_cluster.zig`. Connections live in `src/sim_runtime.zig`. The teeth are in
`src/c1_teeth.zig`. docs/core.md, "Certificates (B4 slice 3)", describes the model.

## Decisions

- **The simulator issues certificates itself, because slice 2's request does not exist yet.**
  `sim_certs.issue` reads the job, its status, and the claim and assignment of the node the status
  names. It reads them from the store as committed: the tap's memory store, beneath the faults,
  which uses up no fault countdown. It then calls the real rule, `job_cert.decide`. The checker
  (`issued_problem`, `conns_problem`) reads the records itself and does not call `job_cert`. Once
  slice 2 lands, the supervisor's ask should go through the agent and the server's issuance path,
  as a call that can be cut, dropped or delayed. The checks stay as they are.
- **Forged asks stand for O4.** Until B7 the request is not authenticated, so anyone may ask for
  any run. Without forged asks a stale epoch never reaches the issuer, because a run is never moved
  after it starts and an ended run is refused for that reason first, so the stale-epoch tooth would
  have nothing to bite on. On 15 % of ticks the model forges one ask: an earlier epoch, another
  node, another image, or the holder asking for a run that may have ended. An `ended` forgery is
  lawful if the run has not ended, so it is not counted in `forged`.
- **The issuer's `now` is the asking node's clock.** This is a modelling finding, and it applies to
  slice 2. `JobObserved.started_at_ms` (copied into `JobStatus`) is the agent's `ctx.clock`
  reading: `agent_clock.RealClock`, Unix milliseconds. `decide` compares it with `ask.now_ms`,
  which the server will read from its own Unix clock. A simulated node's clock has an arbitrary
  offset (`sim_clock.zig`), so reading `c.manual.ms` made every honest ask fail with `lifetime`
  (started=774186 against now=1761350010355). The model therefore stands for a server whose wall
  clock agrees with the node's within the simulated rate error. In a real cluster, a node whose
  wall clock is behind the server's by more than deadline + grace + 60 s is refused the same way.
  The rule takes a start in the future as now, but it has nothing for a start in the past. **For
  slice 2 and the supervisor:** issuance compares two hosts' wall clocks. That is a new dependence
  on NTP, and the owner may want to know about it.
- **R6 counts only the node's own `stopped` report**, never a terminal status the controller
  wrote. A cut-off node's container may legitimately outlive the controller's ending: J1 allows
  that overlap, and the node has not yet been told. Under `--c1`, R6 is judged at every revision
  and on every tick. A connection on a container the runtime forgot is a sticky failure
  (`conns_forgotten`), as R1's listener is.
- **A stop closes connections when the container enters `.stopping`, not at its end**, because the
  supervisor ends them at once (`relay_cancel_ms_max`). A container that ends on its own closes them
  in `end`.
- **Determinism.** The model has its own generator, seeded from the run's seed. Worlds without
  relayed jobs (anything not `strong`) draw exactly as before. Strong worlds differ only by the
  model's store reads and node-clock reads, which draw nothing from the world. The pinned seeds
  (`sim-c1-worlds`, `sim-c1-burst`, `sim-c1-regressions`, `sim-c1-regress`, `sim-c1-reuse`) pass
  with the model on: see the slice report.
- **Teeth.** `job_cert_stale` (R4) and `job_cert_long` (R5) are switches inside `job_cert.zig`,
  the real rule, so a tooth weakens the code that slice 2 will serve. `relay_conn_leak` (R6) is
  inside `SimRuntime`. All three imply `strong`. The binaries assert `!c1_teeth.any`, so none of
  them can ship.

## Traps

- `**` (array repetition) and `@typeInfo(E).error_set.?` are gone in the pinned Zig. Use
  `.error_set.error_names.?`.
- Draw `u32`, never `usize`, in the model: `usize` is 32 bits on `wasm32`, so
  `uintLessThan(usize, n)` and `enumValue` draw differently there, and `sim-cluster`'s native and
  WASM reports disagree (`check` caught it on seed 16525981159377107204). Use
  `enumValueWithIndex(E, u32)`.
- `Node.name` is now `pub`, because `sim_certs.supervise` takes the nodes as `anytype`.

## Next

- Slice 2 merge: `job_cert.zig` gains a `c1_teeth` import and two tooth switches (in
  `not_after_ms` and in `decide`'s epoch compare). Resolve any conflict by keeping both switches.
- When slice 2's agent request exists, route the model's honest asks through it, and keep the
  forged asks as raw API calls.
