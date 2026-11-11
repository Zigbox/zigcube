# The `job_evicted` tooth moves from seed 32 to seed 186

Date: 2026-11-11. Status: decided by the supervisor (B2.1 slice 6).

## What happened

The tooth (`sim-c1-teeth-job_evicted`) must make J8's second clause fail in the burst world with
`--strong`. Since #202 only one seed hit: seed 32 of 1..60. B2.1 slice 6 fixed #205 (one run's
failing step no longer aborts the agent's job pass), which changes what a pass does and so the
simulated world. On the changed code seed 32 no longer fires; the base commit still did.

## Seeds searched

On the slice's code, with the fault on: 1..140 (no hit; seed 44 fails J6 with the fault on and
with it off, on the base commit too, so that is not this change), then 141 upward in blocks of 10
until the first hit: seed 186. Seed 186 passes with the fix on (the `sim_c1_evict_world_main` runner) and the
tooth catches it. Seeds between 141 and 186 that other workers had not reached were not searched.

## Decision

The tooth's range now ends at seed 186 and CI's run starts there (`build.zig`, `c1_teeth_roots`).
The tooth stays in `sim-c1-teeth`'s must-fire set.

The fleet canary does not run fresh seeds at drawn operations for this tooth: that world costs
about 55 s a seed, and a one-in-a-hundred hit would need about 186 seeds, roughly 2.8 hours,
against `SIM_FLEET_BATCH_TIMEOUT` (3,600 s). Its manifest line is the fixed range `186+1@300`
(`FIRST+COUNT@OPS`, `ops/sim-fleet/run.sh`): seed 186 alone at 300 operations, `--c1`, the
runner's default profile, as the CI tooth runs it. It finishes in about a minute. What it can
catch: the clause stops firing at seed 186 (a regression of the check or of the tooth's fault).
What it cannot: a general loss of the clause at other seeds; that needs #217's wider world.
Any change to the agent, the controllers or the simulated world can move the hit again, and then
CI's tooth run and the canary both fail until a new seed is found.

## Consequence

J8's second clause is guarded by one seed. Any change to the agent, the controllers or the
simulated world can move it again; widening the tooth's world so that many seeds hit is B3 work.
