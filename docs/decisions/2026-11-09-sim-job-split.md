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
| `simulations (sim-c1 negative tests)` (`sim-teeth`) | `sim-c1-teeth` | about 24 min |

`sim-c1-teeth` stays one step: it also runs each tooth's plain run, which the per-tooth steps
(`sim-c1-teeth-NAME`) leave out, so splitting it would need a `build.zig` change. It has about 6
minutes of room under the new timeout; a further tooth should go in a split of that step.

`.github/ci-changes.sh` is unchanged: all three jobs run on `code`, as `sim` did. Each job has its
own cache entry (`sim`, `sim-worlds`, `sim-teeth`).
