# The local job fence across restarts, and J12

*Decided 2026-11-15, by the fix session of PR #262 (claude/j6-option-b), from the two reviews
posted on it. It extends docs/decisions/2026-11-15-j6-jobs-local-fence.md and supersedes nothing.
With that file it closes the gap recorded in docs/decisions/2026-11-14-j6-runs-unread-gap.md,
which is merged and so is not edited to point here.*

## The fence's clock survives a restart on the same boot

Review A (agent.zig:505): an agent that crashes in a loop while its runs read fails restarted the
local job fence's term at every start, so a job could outlive the fence for as long as the loop
lasted. Now:

- The lease file has one more field, `runs_unread_since_ms`: the send time of the last runs read
  that succeeded, monotonic, in the file's `boot_id`, written only while reads are failing
  (`Agent.runs_failing`) and left out of the file otherwise. A file without it (written before
  this change) reads as before. An agent before this change reads a file that has it as damaged
  and fences: only a downgrade while reads fail does that. Restore now ignores fields it does not
  know, so a later field will not.
- It is written where the lease file already is (`Agent.persist`: each keepalive, the fence's
  start), and once more when a runs read succeeds after failing (`Agent.runs_read_ok`), so a
  value is never left behind past the recovery. A failure to write it then fails the step like a
  keepalive's; the file keeps the older time, which fences earlier, never later.
- On restore, under the lease's own rule (same boot, send time not in the future), the agent
  takes `runs_read_mono_ms = min(its first step, since)` and counts on as failing. A different
  boot fences anyway (the lease rule), so nothing more is needed there.

No user-visible bound, limit or default changes: the term is the lease fence's, as before; no code
is registered.

**Limit.** A read that starts failing is written at the next keepalive, not at once (writing on
the failure would add a write to a step whose diagnostic is already set). An agent whose lives are
all shorter than one renewal (`fencing.renew_after_ms`, a third of the ttl or less) and that never
reaches a keepalive in any of them still restarts the term each time. Each such life also never
renews the lease, so the lease fence falls on the node within a ttl of the last renewal anyway,
with its own bound.

## The grace under the fence is a policy

Review B: the clamp of the grace to `fence_stop_ms` under the local job fence was described as
something J6's bound needs. It is not (J6's stop branch allows the run's own grace); it is kept
as a policy, so a job is gone by the time the lease fence's own kill would come, and it now holds
for a stop already under way too: `stop_run` lowers a pending stop's deadline to `fence_stop_ms`
from the fence. The comment in `enforce_one` says so.

## J12 and the `job_pass_break_fenced` tooth

Review A (agent.zig:362): with the fence on, the agent before #247's fix (a job pass skipped
after a server failure) no longer breaks J6, because the fence covers it within J6's bound. So a
regression of #247 would pass the simulation. J12 (`sim_cluster.zig`, `judge_job_fence`) catches
it: whenever the local job fence starts to stop a job container on a node,

- no step since the node's last answered runs read may have skipped the job pass (it sent the
  replicas read, ended with the agent up and not fenced, and made no runs read:
  `Agent.runs_reads` unchanged), and
- the fence may not fall within a term of the last runs read the server answered (judged before
  every call, by the send time).

A hung or slow call that uses up the term is a legitimate fence (seed 30 of the runs-unread world
showed one), which is why the first clause counts skipped passes rather than reads not tried.

`sim-c1-teeth-job_pass_break_fenced` is the `job_pass_break` agent with the fence kept on: J12
must fail it. It is sparse: seeds 2 and 44 of the evict world fail J12 (measured over seeds 1..80,
225 and 44; seed 225 fails J6 first). The `job_pass_break` tooth itself (fence off, J6) is
unchanged.

## The runs-unread world reports what it tested

`sim-c1-runs-unread` prints `sim-cluster: runs unread cuts=N fenced=M` (cuts of the runs read the
world made, job containers the fence began to stop) and fails when either is 0, as a range in
which the fault never bit tested nothing.

Where: `src/agent.zig` (`LeaseFile.runs_unread_since_ms`, `runs_read_ok`, `restore`),
`src/agent_jobs.zig` (`pass`, `stop_run`, `enforce_one`), `src/sim_cluster.zig` (J12),
`src/sim_cluster_main.zig`, `build.zig` (`c1_teeth_roots`), `src/agent_jobs_test.zig`,
`docs/core.md`.
