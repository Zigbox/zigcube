# B2 slice 4, part 2: the lost state directory, RB-N8, and what was left

## Decided

- **A wipe is a disk loss (RB-S2 c).** Every fifth crash (the 3rd, 8th, ...; chosen by the crash
  count, no PRNG draw, so other worlds keep their streams) marks the node; its restart then
  empties the state files (`SimState.wipe`) and the containers (`SimRuntime.wipe`). The
  simulated runtime lists containers from the state files, so wiping only the files left
  orphan containers and an assert in `start_impl` (seeds 3 5 7 9 12 20). `load_pair`'s
  `catch unreachable` survives a wipe: an absent file reads as first start. Sweeps, seeds
  1..200 plain and `--c1`: 0 of 400 fail with wipes on.
- **Tooth `job_wipe`.** With the fault on, the agent treats an absent start record of a run
  the store shows as claimed as a fresh start and starts it again (`agent_jobs.restart_fresh`).
  Plain and `--c1` fail J2 (and now and then J7). Hit rate on the merged head, 100 operations,
  seeds 1..200: 23 plain, 19 `--c1`; `canary_seeds` 250 (floor 0.08, miss 8.9e-10).
- **RB-N8.** `watch_max` is `constants.jobs_max` (512) and an overflow fails the run
  (it used to drop containers unjudged). A wedged node is judged for J8 and J6, which
  subtract wedged time; only J1, which has no wedge allowance, still skips it. Sweeps, seeds
  1..200 plain and `--c1`, 100 operations: 0 of 800 fail.
- **`job_unclaimed` canary_seeds** 60 (measured 76 of 200 plain, 90 of 200 `--c1`).

## Not done

- Teeth for more than 512 runs on a node and for job-name reuse: both need runs to be deleted
  by retention, which waits `job_finished_age_ms_min` (1 h); the sim runs minutes and names
  are `jb-N`. They need a clock-skipping retention step or a unit-level tooth, not a sim one.
- Slow seeds: the cost is `MemoryStore.find`/`select_page` scanning the unsorted `live`
  table (docs/core.md, "The cluster simulation"). The fix is a key index in `store_memory.zig`.
- Lease ttl draw: asked the supervisor; 8,000 ms is the product inequality's floor.
