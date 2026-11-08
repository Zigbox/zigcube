# RB-N8 teeth `job_evicted` and `job_reuse` are not built (issue #195)

The WIP note of this branch (`2026-11-08-b2-rbn8-teeth-wip.md`, never on `main`) is replaced by
this one. Neither tooth is in the build. Measured on `fbca677` merged with `main`:

## `job_evicted`: the fault cannot be reached

- Question 1, answered: in the evict world (one node, bursts of 12 creates, 300 operations, seeds
  1 and 2) `gone` was reached with a start record past `claiming` **zero times**. An ended run is
  released, and its record removed, before the runtime evicts its stopped container, so an
  evicted container never has an assigned start record. J2 cannot be produced by this fault.
- The alternative (report `lost` over a stopped observation) was not built: a report over an
  already stopped observation is a no-op for the server, so no check would see a symptom, and a
  tooth must fire a check.
- The evict world with the agent right failed J8 on seed 2 ("a run kept executing past its
  deadline") at 300 operations. Not investigated; likely the burst load, as the WIP note guessed.
  Do not rely on that world without finding out.

## `job_reuse`: too slow to measure

- Even with the one-hour wait taken in 2 s ticks (instead of 36,000 ticks of `tick_ms`), 10
  seeds at 300 operations did not finish in 30 minutes. No hit count was obtained over seeds
  1..40; the symptom (J8) stays a guess, and whether leftovers survive retention is unverified.
- What would be needed: a store-side retention jump that does not tick every agent and check
  (a different seam in `Cluster`), then measure.

## Kept

`jobs_converged` reads up to `job_admitted_window_max` runs, not `jobs_max`. Ended jobs stay
until retention, so a run that creates more than 512 jobs makes `main` fail with "the job
job_runs cannot be read". `main` can hit it in a long run; no check's meaning changes.

## Not done

AGENTS.md and docs/core.md teeth lists, the "seventeen" text and `sim-c1-worlds` in CI are
unchanged, since no tooth was added. #195 stays open.
