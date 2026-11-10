# J6 seed 102: the per-step call floor starves the agent's reads (#142, reopened)

Status: fixed with option 1 (supervisor's choice); see "Fix" at the end.

Replay (main e1e9bc0): `sim_cluster 102 112 1 --c1 --strong --profile=slow_store --lease-ttl-ms=10000 --replicas-pct=100 --heal-at=99`
fails J6 at 133142 ms: stop committed at 120416, run still executing 12726 ms later (bound 12000).

## Cause (real agent behaviour, not the check)
- Heartbeats succeed throughout (`sent` advances), so the fence never fires; J6's fence term
  assumes renewals stop when reads do.
- Five consecutive steps (123816..130408) failed with ZC-E0503 "the reply came too late" on
  `assigned`, `observed`, `job-observed` reads. Their timeouts were 28..652 ms, far under the
  fence: the cap was a run's wake, not the fence.
- `Agent.calls_deadline_ms` gives `max(deadline_wake, now + call_inflight_min_ms)` (1000 ms),
  but `cap_calls` computes it once per step (start, and after the heartbeat) and the client
  counts down from it. Its doc says "a call in flight less than `call_inflight_min_ms`", so the
  floor is meant per call, but it is a budget shared by all of a step's calls (4+ reads).
- In this world many short-grace jobs (grace 153 ms) keep a run wake within a second of every
  step (wake=1076712, 1077981, 1078852, 1080133 in the trace), and slow_store round trips are
  0..907 ms, so 1000 ms rarely fits the reads. The `runs`/stop read never completes; the stop
  is unseen until the wakes stop.

## Evidence
Raising `call_inflight_min_ms` to 3000 (assert relaxed) makes the seed pass (worst stop 9692 ms).
Not committed: it breaks the asserted relation to the grace and loosens the J8 lateness the
floor was sized for (#198, #202).

## Options (supervisor's choice; a bound changes)
1. Real fix: enforce deadlines between calls (a before-call hook on `Deadline` that runs
   `enforce_deadlines` and re-caps), so the 1000 ms floor really is per call and lateness stays
   one call. Touches `agent.zig`, `agent_client.zig`, `agent_run.zig`, `sim_cluster.zig`.
2. Stop reads first: fetch `runs` before the replica loads so a cancel is seen within the first
   budget. Smaller, but only reorders the starvation.
3. Widen J6's bound: not recommended (the stop really is unread, not slow by design).

## Fix (option 1)
`Agent.Deadline` gets an optional `hook_fn`; `cap_calls` registers `Agent.before_call` through it
and `RemoteStore.exchange` runs it before every call (`Context` of the step is kept in
`Agent.calls_ctx` for the step's length). `before_call`, if a run's wake (deadline or kill) is
due, lists the containers and runs `enforce_deadlines` with a diagnostic of its own (the step's
may hold a kept failure), then gives the call `calls_deadline_ms(now)`: the 1000 ms floor is per
call, and a run is enforced at most one call late. `call_inflight_min_ms` (1000), its assertions
against the grace and fence poll, and J6 and J8's bounds are unchanged. A wake that is not yet
due costs only the re-cap (no listing), so a quiet step makes no extra runtime calls.
The simulator (`sim_cluster.zig`) and the test world (`sim_world.zig`) wire the same hook.

Tests: `each call of a step gets its own floor when a run's wake is near` (eight runs 100 ms
apart, every agent call costs 150 ms of the clock: no call is cut; with the hook disabled, 4
are). The replay line is in `c1_regressions`; seed 102 now stops its run within 2700 ms.
