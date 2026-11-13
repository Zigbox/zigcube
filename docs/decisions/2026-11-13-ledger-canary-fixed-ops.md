# The `job_ledger_small` canary runs a fixed range at 400 operations

Date: 2026-11-13. Status: implementer's decision for #236; no check changed.

## What happened

The fleet filed #236: "sim_c1_teeth_job_ledger_small failed no seed", seeds 3336978864..3336978873
(drawn operations, `--profile=auto`, `--c1`).

## Evidence

- Replayed on f7736a7: 0 of 10 fail. The drawn operations were 52, 84, 99, 106, 106, 108, 177, 192,
  308 and 329. A run of 308 operations created 12 jobs and the simulation judged 9 starts: a
  ledger of 16 runs does not fill.
- The same runner at 400 operations, seeds 1..10, `--c1`: 8 fail with "J8: the start ledger is
  full (16 runs)". J8's ledger clause still has its teeth.

So the tooth cannot fire in most drawn worlds; the canary's shape was wrong, not the check. The
README row said "400 operations" and "not measured (caught at seed 1)", and `build.zig` had set
`.ops = 400` for the tooth's own test but left the canary on fresh seeds at drawn operations.

## Decision

The canary is the fixed range `1+15@400` (`canary_first = 1`, the manifest form `FIRST+COUNT@OPS`
that `job_evicted` uses). Catch rate 0.8, 15 seeds: a miss of a working check has probability
0.2^15 = 3e-11. Like any fixed range it re-proves those seeds, so a change that moves the world
may need the range moved (as `job_evicted`'s was). No check was weakened.
