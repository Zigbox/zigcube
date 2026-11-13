# The fleet's coverage bias: one round in two, after 100 seeds a profile

*Decided 2026-11-13, by the supervisor, approving the values C3 slice 3 proposed
(`docs/decisions/2026-11-13-coverage-feedback.md`).*

- **`SIM_FLEET_BIAS_ONE_IN=2`.** With `SIM_FLEET_PROFILE=auto`, every other round runs each
  cluster kind on the profile `sim_fleet bias` names; the other rounds still draw the profile from
  the seed. Half and half steers toward what the fewest seeds reach without letting the bias
  starve the profiles it does not name, and a fleet stuck on one profile is undone the next round.
- **`seeds_min=100`.** A profile with fewer than 100 seeds of the commit in use is run first
  (fewest first), so each profile is sampled before its share of reached counters is compared;
  100 seeds is one cluster batch (`SIM_FLEET_BATCH_CLUSTER`), so every profile is sampled within
  the first few biased rounds after a new commit.

How to change: `SIM_FLEET_BIAS_ONE_IN` is set in the host's `/etc/sim-fleet/fleet.env` (a number;
0 never biases, 1 biases every round; `run.sh` refuses anything else). `seeds_min` is a constant
in `src/sim_fleet_coverage.zig`, changed in code and reviewed like any other.

Where: `ops/sim-fleet/README.md` item 6, `ops/sim-fleet/fleet.env.example`, `ops/sim-fleet/run.sh`
(`bias_pick`), `src/sim_fleet_coverage.zig` (`choose`).
