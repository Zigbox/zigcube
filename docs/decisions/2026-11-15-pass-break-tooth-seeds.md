# The job_pass_break tooth's seeds: 225 and 5 (was 225 and 44)

Date: 2026-11-15. C4 slice 5, fixup 1.

## What happened

`sim-c1-teeth-job_pass_break` runs the `job_pass_break` tooth (the agent's job pass ends at the
first server failure, as before #247's fix) in the `job_evicted` world at 300 operations, `--c1`,
and J6 must fail at each of its known seeds. On `claude/c4-slice4` (cc5fefc) seed 44 no longer
fails, so `zig build check` failed; on main 65e6ece it still fires. C4 slice 3 changed the
`--strong` world (the service replicas' certificates), and the evict world is a strong world, so
seed 44's draws now lead elsewhere. The tooth did not lose its strength: seed 225 still fails J6
at 21,596 ms.

## The new seeds

- Seed 225 kept: J6 at 21,596 ms with the tooth.
- Seed 5 added in place of 44: J6 at 53,656 ms ("a run kept executing after its stop committed,
  past the bound").
- Searched: seeds 1 to 30 at 300 operations with the tooth (`sim_c1_teeth_job_pass_break SEED
  300 --c1`); seed 5 is the only hit there, so the tooth stays sparse, as it was (one hit in
  1..40 before).
- With the tooth off (`sim_c1_evict_world_main SEED 300 1 --c1`), seeds 5 and 225 both pass.

`build.zig` (`also_seeds`), the canary manifest it generates, `AGENTS.md`,
`ops/sim-fleet/README.md` and `docs/core.md` name 225 and 5. The merged decision
`2026-11-14-b3-soak-after-247.md` still says 44; it records what was true then.

Any later change to the strong world can move these seeds again: the guards of #247 are its unit
tests in `src/agent_jobs_test.zig`, and the tooth only proves the simulator can see the fault.
