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
until the first hit: seed 186. Seed 186 passes with the fix on (`sim-c1-worlds` runner) and the
tooth catches it. Seeds between 141 and 186 that other workers had not reached were not searched.

## Decision

The tooth's range and the fleet canary (1..186) now end at seed 186 and CI's run starts there (`build.zig`,
`c1_teeth_roots`). The tooth stays in `sim-c1-teeth`'s must-fire set.

## Consequence

J8's second clause is guarded by one seed. Any change to the agent, the controllers or the
simulated world can move it again; widening the tooth's world so that many seeds hit is B3 work.
