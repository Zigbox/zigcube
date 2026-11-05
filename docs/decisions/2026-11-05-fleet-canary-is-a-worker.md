# The fleet's teeth canary is one of its own workers

*Decided 2026-11-05, by the slice (C3 fleet 2, after review of PR #97).*

The teeth canary (docs/briefs/c3-sim-fleet.md, item 3) proves that the fleet, as deployed, still detects. A canary that repeats CI's teeth gates (seeds 1..10, fixed operations, `--expect-fail`) and reports a line `run.sh` composed itself proves only what CI already proved, and nothing about the fleet's reporter. So:

- The canary runs as one more worker of a round, on a fresh random seed range, with drawn operations and `--profile=auto`, the widest settings the fleet runs, and without `--shrink`. The owner decided that on 2026-11-05, after the review of PR #97: a caught fault needs no shrinking and a miss has nothing to shrink, and a shrink of a failing seed costs minutes of the canary's turn. The other kinds keep `--shrink`; the replay line in a canary's issue has none.
- Its real output goes through `sim_fleet ingest --canary`, which reads it with its kind's parser. A miss, a wrong symptom and a crash are judged there (`issue.canary_verdict`), from the parsed batch, and filed under the kind `sim-canary`. A miss and a wrong symptom have different fingerprints (steps `canary` and `canary-symptom`).
- The runners, their kinds, seed counts and symptoms come from one manifest that `build.zig` generates from `c1_teeth_roots` and installs with `sim-canary-exe`, so `run.sh` copies nothing.
- The canaries run in a fixed cycle, not drawn at random, so each runner is checked once every 8 × `SIM_FLEET_CANARY_ONE_IN` rounds. A canary that GitHub held back or the host kept from running runs again next round, at most 5 times in a row (`SIM_FLEET_CANARY_TRIES_MAX`), counted once; one the reporter refuses (exit 1) keeps its output and the cycle moves on. A memory kill (137) and a run where no seed could start are host events (`NOT RUN`): counted, never filed.
- Each runner's seed count holds a miss by chance below 1e-9 per run at an assumed catch rate well under the one measured. The table is in `ops/sim-fleet/README.md`.

A crash is never "could not start" (`Failure.infra`), even in step `setup`. Before this change, a cluster crash that traced no step was both, so it was not filed and it tripped `counts_of`'s assert.

Where: `ops/sim-fleet/README.md` (item 4), `ops/sim-fleet/run.sh` (`canary_pick`, `canary_report`), `src/sim_fleet_issue.zig` (`canary_verdict`), `build.zig` (`canary_manifest`).
