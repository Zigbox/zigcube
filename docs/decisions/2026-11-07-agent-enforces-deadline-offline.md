# The agent enforces a run's deadline without the server

Status: decided (release review of PR #147, reviewer 1, MUST 1).

## Decision

- Every agent step, after the fence check and **before any call to `zcube-server`**, lists the
  runtime and reads the start records (`agent_jobs.enforce_deadlines`). A `claimed` run of this
  boot past `deadline_mono_ms` gets `stop_cause = deadline` in its start record, then TERM; the
  kill follows when its grace ends (`Agent.stop_listing`, as before).
- The next deadline or kill is a wake (`Agent.deadline_wake_mono_ms`). `Agent.act_in_ms` (the
  loop's pause and the watch hold) and `Agent.calls_deadline_ms` (the cap on every remote call,
  `ZC-E0503` past it) take the sooner of it and the fence. So a cut link, a hung call, a backoff
  or a run whose report keeps failing never holds a stop back.
- The existing pass (`agent_jobs.pass`) still reports the ending, with the recorded cause, once the
  server answers. Its per-run loop is unchanged (another session works on that file).
- J8's bound is back to `deadline + grace + rate error + kill latency + granularity + wedged time
  after the deadline`: no term for a cut link or store, and none for the fence. The link-cut
  bookkeeping in `sim_cluster.zig` (`link_cut_total_ms`, `call_failed`) is gone. The granularity
  is the simulator's own (a tick and two check intervals, 2,100 ms), not a user-visible bound.
  J6 keeps the fence term: a `stop` committed on the server does need the server or the fence.
- `ZC-E0503` gains no new code; its cause text now names a run's deadline as well as the fence.

## The tooth, and whether the drawn space has the world

`sim-c1-teeth-job_deadline_offline` turns local enforcement off, so only the pass (which needs the
server) or the fence stops a run: the old behaviour.

- In the normal drawn space the world exists but is rare: the tooth fails seeds 4 and 13 of
  `--seeds 1..40 auto --profile=auto --c1`, 2 of 40 under `--profile=partitions` at 100
  operations, 0 of 40 under `mixed` at 100 operations. The fence bounds the old overrun, so a
  deadline must fall in the few seconds between a cut and the fence.
- So the tooth, as `skew_beyond_bound` does, turns its world up: partition weight 25, cuts up to
  4× longer (to 33 s), job creation weight 20 and short deadlines 3 to 13 s. It then fails 11 of 40
  at 100 operations (4, 5 and 7 in 1..10). The same worlds with local enforcement on: 0 of 40.
- Its canary runs 80 seeds (floor 0.25), as `job_cancel`.

## Traps

- `runtime.list` now comes before the heartbeat, so the step's listing is older by one call;
  `publish_store` and the pass use the same listing, as before.
- A failure in `enforce_deadlines` (a state-directory write) fails the step before the heartbeat.
  A persistent one ends in the fence, as any persistent failure does.
- A wake that is already due (a step failed before it got there) is retried at `fence_poll_ms`,
  not at the fence: otherwise a failed step could pause a stop for seconds.
