# CI's sim job split in three (B2.1 slice 1)

The `sim` job took 47 to 51 minutes against a 60-minute timeout (#205). It is now three jobs that
run side by side, each with `timeout-minutes: 30`. Every step, command and seed is kept; the steps
only moved.

Timings used (run 42593341663, job 129080041354, push to `main` at c613312, 47 min 14 s in all,
about 2 min of it checkout, Zig and cache):

| step | time |
|---|---|
| sim-c0 seed 1 / seed of the run | 25 s / 1 m 12 s |
| sim-c1 seed 1 / seed of the run | 35 s / 1 m 18 s |
| sim-c1 negative tests | 21 m 56 s |
| offline-deadline world | 1 m 51 s |
| burst world | 4 m 04 s |
| worlds | 7 m 54 s |
| regressions | 2 m 09 s |
| regression seeds | 2 m 21 s |
| fencing negative test | 1 m 32 s |

| job | steps | estimate |
|---|---|---|
| `simulations (sim-c0, sim-c1)` (`sim`) | the four seed runs, regressions, regression seeds, fencing | about 12 min |
| `simulations (sim-c1 worlds)` (`sim-worlds`) | offline, burst, worlds | about 16 min |
| `simulations (sim-c1 negative tests)` (`sim-c1-teeth`) | `sim-c1-teeth` | about 24 min |

`sim-c1-teeth` stays one step: it also runs each tooth's plain run, which the per-tooth steps
(`sim-c1-teeth-NAME`) leave out, so splitting it would need a `build.zig` change. A further tooth
should go in a split of that step.

The job was called `sim-teeth` when this was written; it is `sim-c1-teeth` now (the job key, its
cache entry and its comment). The `zig build sim-teeth` step, which is the sim-c0/sim-cluster
teeth build, is a different thing and keeps its name.

Measured, CI run 42681840689 (B2.1 slice 1, before the rename), each job's wall time:

| job | measured | estimate above |
|---|---|---|
| `simulations (sim-c0, sim-c1)` (`sim`) | 7 min 45 s | about 12 min |
| `simulations (sim-c1 worlds)` (`sim-worlds`) | 19 min 22 s | about 16 min |
| `simulations (sim-c1 negative tests)` (`sim-c1-teeth`) | 20 min 25 s | about 24 min |

`sim-worlds` came in about 3 minutes over its estimate. B2.1 slice 5 widens that world, so it is
the job to watch: it has about 10 minutes of room under its 30-minute timeout, and the next widening
should split it again before it nears the limit. `sim-c1-teeth` has about 9.5 minutes of room.

`.github/ci-changes.sh` is unchanged: all three jobs run on `code`, as `sim` did. Each job has its
own cache entry (`sim`, `sim-worlds`, `sim-c1-teeth`).
