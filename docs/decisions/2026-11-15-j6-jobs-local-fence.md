# J6: the local job fence (option B, built)

*Decided 2026-11-15, by the J6 option B slice (claude/j6-option-b). It builds the owner's choice
recorded in docs/decisions/2026-11-14-j6-runs-unread-gap.md and does not supersede it.*

## What the agent does

The agent keeps `runs_read_mono_ms`: the monotonic time at which it **sent** the last read of its
job runs that succeeded (`agent_jobs.pass`; a pass with no assigned run to read counts as a read
at its start). The local job fence falls at

    fencing.fence_at_ms(runs_read_mono_ms, lease_ttl_ms) = runs_read_mono_ms + ttl - fence_margin_ms

the lease fence's own term (`Agent.job_fence_at_ms`). From then on, `enforce_deadlines` (run at
every step's start and in `before_call` when its wake is due) stops every job container still
running:

- it writes cause `unreachable` into the start record (unless a cause is already there: a cancel,
  or a deadline that came due, keeps its own), as the cause the server gives a run it no longer
  serves (`job_controller.map_ending` maps it to failed(unreachable));
- SIGTERM, with grace `min(record.grace_ms, fence_stop_ms)`, then SIGKILL;
- a container whose start record is missing, damaged or unreadable is stopped too, with
  `fence_stop_ms`.

Before the fence, its time is a wake (`deadline_wake_mono_ms`), so `next_wake`, `act_in_ms` and
the call cap (`calls_deadline_ms`) all honour it: a hung or slow call never keeps a job past it.
Replicas, the lease and the tenure are untouched: the node is not fenced.

## Why this start, and this term

A read that succeeds, sent at S, reflects every stop committed before S. A stop committed at t is
therefore seen by the first good read sent after t, or the run is fenced by
t + ttl − fence_margin_ms + fence_stop_ms + the kill's latency. That is the "fenced" branch of
J6's bound (`sim_jobs.stop_bound_ms`), so J6's bound does not change, and no new constant, bound or
code is added: the owner's choice named "the same term as J6's fence". The supervisor approved
the term, and the fault's 60 s window below, on 2026-11-15, before either was fixed.

## Limits

- It needs a lease (the ttl is the lease's); without one there is no fence of either kind.
- Across a restart on the same boot, the lease file keeps its clock while the reads fail
  (docs/decisions/2026-11-15-job-fence-survives-restart.md). Otherwise a restarted agent counts
  from its first step (`reconcile` sets it).
- A node whose runs reads keep succeeding never meets it.
- It overlaps #247's fix only in part. A step whose job pass is skipped after a server failure
  before the runs read makes no runs read, so the fence bounds it within J6's fenced bound. A
  pass that reads the runs and then breaks moves the fence on with that read, so the fence never
  bounds it: with the fence kept on, the agent before #247 (`job_pass_break_fenced`) still fails
  J6 at seed 225 of the evict world, at the same time as with it off (21,596 ms). #247's fix is
  what stops a committed run within a resync, and its unit tests in `agent_jobs_test.zig` guard
  it. The `job_pass_break` tooth turns the fence off, as the agent before #247 had none; the
  simulation's J12 guards #247 with the fence on
  (docs/decisions/2026-11-15-job-fence-survives-restart.md).

## The tooth and the world

- `c1_teeth.runs_unread_world` is the world: the server fails a node's runs read for 60 s after a
  run's stop commits (`runs_unread_window_ms`, test-only, `agent_api.zig`) and answers everything
  else. The tooth's first version cut the read for as long as the stopped run stayed assigned;
  since a failed job pass ends the step's stages, the agent's reports and orphan stops then never
  went out, nothing converged, and seeds failed checks that are not J6's (J8, an orphan service
  container, an unreported replica) with the fence on or off. A bounded outage is the fault J6
  is about.
- `sim-c1-teeth-job_runs_unread` is that world with the fence off (`c1_teeth.job_runs_unread`):
  J6 must fail.
- `sim-c1-runs-unread` (`src/sim_c1_runs_unread_main.zig`) is the world with the fence on, seeds
  1 to 40 at 100 operations, `--c1`: every check must hold. CI's `sim-worlds` job runs it.
- Unit tests in `agent_jobs_test.zig`: a runs read that keeps failing while keepalives are answered
  stops the job at the fence (cause `unreachable`) and keeps the replica, the lease and the
  tenure; a runs read that answers moves the fence on, so a steady node never meets it.

Where: `src/agent.zig` (`runs_read_mono_ms`, `job_fence_at_ms`), `src/agent_jobs.zig` (`pass`,
`enforce_deadlines`), `src/agent_api.zig` (`runs`), `src/c1_teeth.zig`, `build.zig`
(`add_runs_unread_step`, `c1_teeth_roots`), `docs/core.md`, `docs/agent.md`.
