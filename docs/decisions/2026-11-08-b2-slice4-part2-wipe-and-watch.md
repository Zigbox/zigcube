# B2 slice 4, part 2: the lost state directory, RB-N8, and what was left

## Decided

- **A wipe is a disk loss (RB-S2 c), in the strong world only.** `--strong` (drawn by `auto`
  operations, forced by the teeth `job_wipe` and `job_unclaimed`) marks the node on every other
  `.host` crash (the 1st, 3rd, ...; chosen by the host-crash count, no PRNG draw); its restart
  empties the state files (`SimState.wipe`) and the containers (`SimRuntime.wipe`). Without
  `--strong` a run is its old world bit for bit (review of PR #191, SHOULD 3). The simulated
  runtime lists containers from the state files, so wiping only the files left orphan
  containers no agent can list. A `.process` crash never wipes: a hand-deleted state directory
  would leave such orphans (a trial with the containers kept failed 42 of 200 seeds, J8 and I1b,
  whatever the agent does); it is a coverage cut, recorded in docs/core.md. `load_pair`'s
  `catch unreachable` survives a wipe: an absent file reads as first start. Sweeps, `--strong`, seeds 1..200,
  100 operations, plain and `--c1`: 0 of 400 fail.
- **Tooth `job_wipe`.** With the fault on, the agent treats an absent start record of a run
  the store shows as claimed as a fresh start and starts it again (`agent_jobs.restart_fresh`).
  Plain and `--c1` fail J2 (and now and then J7). Its symptom is J2 or J7 by name, `|`-separated
  (`src/symptom.zig`; a bare prefix `J` no longer passes). Hit rate, `--strong`, 100 operations,
  seeds 1..200: 26 plain, 26 `--c1`; drawn operations, `--profile=auto`: 25 of 200 plain, 4 of 60 `--c1`; `seeds` 100
  (about 13 hits at 100 operations); `canary_seeds` 300 (floor 0.065, miss 1.9e-9; the `--c1` rate
  is the low one).
- **RB-N8.** `watch_max` is `16 * runtime_handles_max`, and `sim_cluster.zig` asserts at
  compile time that every container of every runtime has a slot, so no live job container is
  dropped unjudged and an overflow cannot happen (merged with main's followups, which chose
  this bound; it proves no container is unjudged, where a `jobs_max` bound needed a run-time
  failure). A wedged node is judged for J8 and J6, which
  subtract wedged time; only J1, which has no wedge allowance, still skips it. Sweeps, seeds
  1..200 plain and `--c1`, 100 operations: 0 of 800 fail.
- **`job_unclaimed` canary_seeds** 60 (100 operations, `--strong`: 79 of 200 plain, 92 `--c1`; drawn operations, `--profile=auto`: 108 and 106).

## Not done

- Teeth for more than 512 runs on a node and for job-name reuse: both need runs to be deleted
  by retention, which waits `job_finished_age_ms_min` (1 h); the sim runs minutes and names
  are `jb-N`. They need a clock-skipping retention step or a unit-level tooth, not a sim one.
- Slow seeds: the cost is `MemoryStore.find`/`select_page` scanning the unsorted `live`
  table (docs/core.md, "The cluster simulation"). The fix is a key index in `store_memory.zig`.
- Lease ttl draw: asked the supervisor; 8,000 ms is the product inequality's floor.
