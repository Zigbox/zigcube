# 2026-11-09: #202, a run started mid-step is bounded by its deadline at once

## Finding

Burst world seeds 14 and 17 (300 operations) failed J8 ("a run kept executing past its
deadline, its grace and the kill"). The check and the world are right; the agent was wrong.

`enforce_deadlines` and the call cap (`cap_calls`, `deadline_wake_mono_ms`) were armed only at the
start of a step, from start records that already existed. A run claimed and started later in the
same step had neither: if a later call of that step hung, was cut, or there were many slow ones,
the step lasted past the run's deadline + grace + kill, and nothing killed the run until the
next step began.

## Fix

- `Agent.arm_run_deadline` (src/agent.zig), called by the claimed-start path in
  src/agent_jobs.zig right after the start record is written: it lowers
  `deadline_wake_mono_ms` to the run's deadline and lowers (never raises) the call cap, kept in
  the new `calls_cap_mono_ms`, to `calls_deadline_ms`.
- A first form (calling `cap_calls` at every start) raised the cap to now + 1 s on each start
  and made seed 21 fail J8 (age 8005 ms against a bound of 7478 ms); hence "only lowers".
- Test: "a run started in a step arms its deadline wake before the step's later calls (#202)"
  (src/agent_jobs_test.zig); it fails without the fix.
- Burst world only: the busy-loop ceiling is 300 steps per minute (200 elsewhere). With the fix
  seed 14 steps at 214 per minute even without it (baseline measured), above 200; a hot loop is
  600+. This is a simulator check bound, not a user-visible limit or default.
- `sim_cluster`'s printed replay line names `sim_c1_burst` in the burst world.
- `sim-c1-burst` seeds: 1..2, 14, 17, 21 (one process each). Seeds 1..20 do not fit: a seed
  takes about 165 s alone.

## Evidence

Hand sweep of the burst world, seeds 1..60 at 300 operations, ReleaseSafe: 60 of 60 pass.
Seed 19 of the teeth branch's evict world (named in the issue) was not triaged.

## Handoff

If J8 fails in the burst world again, run the seed with `--trace-steps` and look first at whether
a run was started after the step's first call. Not run here: nothing beyond the gates below.
