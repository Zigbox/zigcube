# The fleet runs three kinds, and its state counts them

*Decided 2026-11-04, by the sim-fleet-2 slice (to match the release rule: C2 ships after 24 h of the fleet with `sim-cluster`, `--c1` and `sim-swarm`).*

- A round runs `sim-cluster`, `sim-c1` (`sim_cluster --c1`) and `sim-swarm` (`sim_swarm`), one worker each by default (`SIM_FLEET_WORKERS_CLUSTER|_C1|_SWARM`), and ingests each kind with its own `sim_fleet ingest --kind`. The kind is in the fingerprint, so one check failing in two kinds is two issues; the replay line builds `sim-swarm-exe` for a swarm failure.
- `sim_swarm` gained what the fleet needs: a `step:` per failing seed (`fetch`, `locality`, `drop`), the seed and time tail dropped from the check, and `--shrink` (a bisection as in `sim_cluster`). A swarm crash has no step trace, so it is recorded in the step `run`.
- The state file is version 3: `kind DAY KIND SEEDS FAILED` lines count each day per kind. A version 1 or 2 file still loads; a day's seeds not covered by `kind` lines count as `sim-cluster`. The old `sim_fleet` reads only versions 1 and 2, so a rollback past this release deletes `state.txt` (the issue markers rebuild it).
- `day.batches` now counts ingests, one per kind per round; the daily post says "batches".

Where: `ops/sim-fleet/README.md`, `AGENTS.md` (`sim-fleet-exe`, `sim-swarm`), `src/sim_fleet_state.zig`.
