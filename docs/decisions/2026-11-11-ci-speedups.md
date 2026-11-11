# CI speed-ups: cache limit, merged demo jobs, timeouts (2026-11-11)

Owner-approved items 2, 4 and 6 of the CI speed review. No coverage is lost.

## Build cache

Zig's cache never deletes, and entry mtimes are not refreshed on a cache hit (checked with a toy
project), so pruning "what the job did not use" by age is not possible. The guard in
`.github/actions/zig-cache` dropped a restored cache over 1000 MB (uncompressed) and started
cold, which most simulation jobs hit. The limit is now 2000 MB; the entries of five jobs stay
under the repository's 10 GB.

Before (main run 490, restored size, uncompressed): check 1520 MB, sim 1035 MB and sim-c1-teeth
1432 MB were each over 1000 MB, dropped, and built cold (saved entries 148, 102 and 216 MB
compressed); wasm restored 800 MB and was kept.

After (PR run, same sources as main, so every cache was an exact-key hit and nothing was saved):
check restored 808 MB and sim 395 MB, both kept; wasm 906 MB and sim-c1-teeth 822 MB were under
the limit but failed the guard's second test, `zig build --help` ("configuration failed:
FileNotFound"), and started cold. That second failure is not the size problem and is not fixed
here: the entries main saved cannot configure the build in two of four jobs. Why is unknown.

This run cannot show the benefit of the new limit: the benefit appears on the next source change,
when a restore-key hit grows past 1000 MB and is now kept up to 2000 MB. Measure it on the first
PR after this one that changes `src/` (look for `zig-cache: restored N MB` and no `over` line).

## Demo jobs

`demo-c0`, `demo-c1`, `demo-b1`, each for sqlite and postgres (six jobs, each fetching Zig and
building), are now `demos (sqlite)` and `demos (postgres)`: one build, then one step per demo
(`demo-c0 on SQLite`, ...). Each step keeps its `if` on the `demo_c0|demo_c1|demo_b1` output of
`ci-changes.sh`, which is unchanged, so the table test still holds. A failed demo does not stop
the next; the job fails. Transcripts are one artifact per job.

## Timeouts

Every job has `timeout-minutes` at about 2 to 3 times its typical duration on main (changes 5,
check 15, store-postgres 12, store-faults 15, demos 30, wasm 20, sim 25, sim-c1-teeth 30,
sim-worlds 30, zigbox-smoke 20, demo-c2 25, mtls-interop 10, pages 10).

## Teeth count

AGENTS.md's "seventeen teeth" matches `c1_teeth_roots` in build.zig: 23 roots, six earlier ones
(allocation, readiness, stale, skew, wedge, locality) and the 17 job and relay teeth listed.
No change.

## Numbers

| | main run 490 | PR run 492 |
|---|---|---|
| Wall clock | 23 min 08 s | 22 min 06 s |
| Runner time (sum of jobs) | 109.0 min, 17 jobs | 102.6 min, 13 jobs |
| Six demo jobs | 20.7 min | 9.6 min (`demos (sqlite)` 4:45, `demos (postgres)` 4:51) |

The longest job (sim-c1 negative tests, about 22 min) sets the wall clock, so merging demos saves
runner time, not wall time. Each demo in the merged jobs ran and passed, as its own step.
Billed minutes are rounded up per job, so four fewer jobs save a little more than the table.
