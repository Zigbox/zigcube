# job_pass_break: seed 44 replaced by seed 180 in the B4–B7 bundle

*Decided 2026-11-14, by the supervisor (relayed), recorded by the integration session.*

**The tooth.** `sim-c1-teeth-job_pass_break` runs the agent from before #247's fix: its job pass
ends at the first server failure. On `main` it had two known hits in the `job_evicted` world at
300 operations, `--c1`: seeds 225 and 44. Each must fail with J6.

**What changed.** B5 (`--signed`) and B6 (`--tenants`, node labels) change what the simulated
world draws, even on a run that switches neither on. In the bundle, seed 225 still fails with J6
and seed 44 no longer fires. So `zig build check` failed with `sim-c1-teeth: a negative test did
not fire its check` at 1622375.

**Decision.** The supervisor said to drop seed 44 and keep 225 as the gate and the canary, then
search 41..120 for a replacement, and to stop and report if nothing fired up to 400.
- `.also_seeds` is now `&.{180}` in `build.zig`'s `c1_teeth_roots`. The canary manifest is
  generated from it.
- `first_seed` and `canary_first` stay 225.

**The search,** with the fix off (`sim_c1_teeth_job_pass_break`, ReleaseSafe, `--seeds A..B 300
--c1`):

| Seeds | J6 hits |
|-------|---------|
| 1..40 | none |
| 41..120 | none |
| 121..240 | 180 and 225 |
| 241..400 | not run: stopped at the background time limit once 180 was found |

**With the fix on.** Seeds 180 and 225 each pass in the evict world (`sim_c1_evict_world_main
--seeds N..N 300 --c1`: 0 of 1 failed).

**What it costs.** The tooth is as sparse as before: two hits in 240 seeds. The unit tests of #247
in `src/agent_jobs_test.zig` remain the real guard of the fix. Any later change to what the world
draws can move these hits again, and the next one to fail a gate should be reseeded the same way.

Where: `build.zig` (`job_pass_break`), `ops/sim-fleet/README.md`, `docs/core.md`, AGENTS.md.
