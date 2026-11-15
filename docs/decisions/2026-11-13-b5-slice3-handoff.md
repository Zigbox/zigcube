# B5 slice 3: signed jobs in the cluster simulation (handoff)

*Decided 2026-11-13, by the slice (B5 slice 3), within the brief's fixed decisions.*

- **The world is opt-in: `--signed` (`Options.signed`), not part of `auto`.** The fleet's canaries
  run at drawn operations with `--profile=auto`; switching the world on under `auto` (as `--strong`
  is) would give every canary a new world and void the measured catch rates in
  `ops/sim-fleet/README.md`. So `plan()` leaves it alone, and without `--signed` nothing is drawn
  and every world is unchanged bit for bit. The fleet's `sim-c1` workers pass `--signed`
  (`run.sh` `kind_flags`, tested in `test-canary.sh`); a canary does not. `job_untrusted`'s runner
  opens the world itself (`c1_teeth.signed_world`).
- **What `sim-c1` runs.** Its seed twice, without and with `--signed`, each natively and as WASM
  (`zcube_sim_cluster_shaped` takes a ninth argument, `signed`; `tools/wasm_check.mjs` reads a
  trailing `--signed`). `sim-c1-signed` sweeps seeds 1..20 at drawn shapes and profiles, about
  3 minutes (CI's `sim-worlds` job; 40 seeds took about 8). Seed 12 alone is about 70 s, as
  it is without `--signed`.
- **The world** (`src/sim_trust.zig`, core): five keys from the seed (the fifth never trusted),
  fifteen envelopes (each key signs a tree-only statement of the jobs' one tree, one of another
  tree, and one bound to a manifest, which counts for no sim job since `source` is empty), each job
  up to three lines drawn from its number, and per node a policy: none (1 in 8), open (1 in 8) or
  requiring a subset of the four trusted keys. The agent judges with the real `job_trust.judge_run`;
  the simulator's oracle (`admits`) is held to it by a unit test over 8 nodes and 39 jobs.
- **Sub-seeds are hashed** (`stream`: Wyhash of seed, label, index). `DefaultPrng.init(seed ^ c +
  index)` gave a visibly biased first draw for neighbouring indices (about 50 nodes over seeds 1..10 drew no
  `open` policy; a direct count over 3,184 draws of `uintLessThan(u8, 8)` ranged from 200 to 573
  per value). Other simulator files seed sub-generators the same way (`seed ^ constant`); that
  is fine for one stream per constant, not for a stream per index. Not changed elsewhere.
- **J12** has three parts: a start on a node whose policy refuses the run (judged at each start);
  each terminal `/job-status/` put the tap sees (a run that ended `refused` never ends again, is
  not ended `refused` twice, and was placed on a node whose policy refuses it); and at rest (a
  terminal run on a refusing node, with no stop cause, ended `refused`). A run ended by a stop cause
  (cancel, `not_started`, deadline before start) is not judged at rest: those outrank the refusal
  in the agent.
- **The tooth** `job_untrusted` makes `refused_by_trust` return false. Caught by 23 of 30 seeds
  (drawn operations, `--profile=auto`, `--c1`) and 15 of 20 plain (100 operations), always as J12;
  canary seeds 30.
- **The simulated server has no trust configuration,** so every run reaches its node; the server's
  own admission (slice 1) is covered by its unit tests, not by this world.

Nothing in slice 2 needed rework for this slice.

**Next:** slice 4 per `docs/briefs/b5.md`. The tooth's replay lines name `sim_cluster` without
`--signed`, as the strong teeth's do (the runner is the fault-on one); a J12 failure from the fleet's
sim-c1 kind replays with `--signed`.

Where: `docs/core.md` ("Signed jobs"), `src/sim_trust.zig`, `ops/sim-fleet/README.md`, AGENTS.md.
