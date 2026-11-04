# The fleet runs three kinds, and its state counts them

*Decided 2026-11-04, by the sim-fleet-2 slice (to match the release rule: C2 ships after 24 h of the fleet with `sim-cluster`, `--c1` and `sim-swarm`).*

- A round runs `sim-cluster`, `sim-c1` (`sim_cluster --c1`) and `sim-swarm` (`sim_swarm`), one worker each by default (`SIM_FLEET_WORKERS_CLUSTER|_C1|_SWARM`), and ingests each kind with its own `sim_fleet ingest --kind`. The kind is in the fingerprint, so one check failing in two kinds is two issues; the replay line builds `sim-swarm-exe` for a swarm failure.
- `sim_swarm` gained what the fleet needs: a `step:` per failing seed (`fetch`, `locality`; the `drop` step runs but has no check that can fail, so no failure reports it), the seed and time tail dropped from the check, and `--shrink` (a bisection as in `sim_cluster`). A swarm crash has no step trace, so it is recorded in the step `run`.
- The state file is version 3: `kind DAY KIND SEEDS FAILED` lines count each day per kind. A version 1 or 2 file still loads; a day's seeds not covered by `kind` lines count as `sim-cluster`. The old `sim_fleet` reads only versions 1 and 2, so a rollback past this release deletes `state.txt` (the issue markers rebuild it).
- `day.batches` counts ingests, one per kind per round; the daily post says "ingests". The journal line names its kind (`sim-fleet: sim-swarm: N seeds, ...`).

Where: `ops/sim-fleet/README.md`, `AGENTS.md` (`sim-fleet-exe`, `sim-swarm`), `src/sim_fleet_state.zig`.

## Review fixes (Opus review of PR 71, 2026-11-04)

- `sim_cluster --c1` ends in `sim-cluster --c1: seeds A..B, ...`; the sim-c1 parser requires it and the sim-cluster parser rejects it, so a range that ran without `--c1` can never be counted as sim-c1.
- The parser checks each summary's `F of T failed` against the `seed N:` records since the previous summary and `T` against the range; a mismatch refuses the round (exit 1, nothing counted).
- Batch sizes are per kind: `SIM_FLEET_BATCH_CLUSTER|_C1` (default `SIM_FLEET_BATCH`, 100) and `SIM_FLEET_BATCH_SWARM` (default 50000, about 1.5 ms a seed against 1.1 s). The swarm default does not follow `SIM_FLEET_BATCH`, since an installed `fleet.env` sets that to 100 and is never overwritten.
- State `kind` lines with an unknown kind refuse the file (`BadState`).
- Known and not fixed (the review's items 8 and 10): left as they are in this slice; the supervisor holds the text of those findings.
