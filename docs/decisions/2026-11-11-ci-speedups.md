# CI speed-ups: cache limit, merged demo jobs, timeouts (2026-11-11)

Owner-approved items 2, 4 and 6 of the CI speed review. No coverage is lost.

## Build cache

Zig's cache never deletes, and entry mtimes are not refreshed on a cache hit (checked with a toy
project), so pruning "what the job did not use" by age is not possible. The guard in
`.github/actions/zig-cache` dropped a restored cache over 1000 MB (uncompressed) and started
cold, which most simulation jobs hit. The limit is now 2000 MB; the entries of five jobs stay
under the repository's 10 GB.

Before (main, sim-worlds log): restored size over 1000 MB, dropped, cold build.
After: TBD from the PR's run.

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
(allocation, readiness, stale, skew, wedge, locality) and the 17 job and relay teeth listed. No change.

## Numbers

Last full main run: TBD. This PR's run: TBD.
