# J6 on the b3 candidate: a failed read of the reports withheld committed stops (#142)

*Decided 2026-11-14, by the fix slice (claude/b3-j6-142).*

The fleet hit J6 on ebfbac5 (`sim_cluster 2821617909 100 3 --c1 --strong --lease-ttl-ms=10000
--replicas-pct=200 --heal-at=130`): run `jb-10` on node3 ran 12,602 ms after its cancel committed,
past the bound of 12,000.

## Cause (an agent bug)

Node3's trace, true time:

- 102,187: a step starts. Its calls take 5,771 ms (mixed profile, slow replies). It reads `runs`
  with no stop, claims `jb-10` and starts it at about 106,677. The cancel commits at 102,387, while
  the step is running. The simulator answers a step's reads in the order of its events, so the
  read comes before the cancel. A real agent's read at about 105,565 would have seen the stop.
  That part is the simulator's coarseness, which docs/core.md already accepts (a step runs whole
  at its start).
- 108,001: the next step. The keepalive succeeds (569 ms), and so do `replicas`, `assigned`,
  `observed` and `runs` (the stop is shown at about 110,400). Then `GET job-observed` is cut after
  4,610 ms (ZC-E0503). `agent_jobs.pass` used `try` on that read, so the pass returned and no
  `stop_only` ran. The stop the pass already held waited for a later step. The keepalive had
  just renewed the lease, so J6's fence term could not apply.

The second half is a real agent bug: one slow read held back a stop that the agent already
knew. With a store that answers keepalives and times out that read again and again, the stop
waits for as long as that goes on. #247 fixed the same problem for a failure inside the stages
(a replica stage, the job pass's loop). Two other places had it too, and the review of this
fix found them: the read of the reports, between the runs read and the loop, and every call of
the step between the keepalive and the stages, `publish_store` (the image summary) and
`Pass.load` (replicas, `/assigned/<node>/`, replica observed). A step that failed there
returned before the job pass, so it never read the runs at all.

## Fix

Each of those failures is kept like a stage's (`Kept.stage`) when it is not the runtime's: the
pass reads the runs, makes no write, and every subject goes through `stop_only` from the runs it
read. After a failed loading nothing is loaded (`Pass.load` sets its fields after its last read),
so no replica is reconciled and the subjects come from the listings and the start records alone.
The bounds do not change.

`Kept` keeps as the step's error, the one `why` shows, the first failure that stopped the
stages: a runtime failure kept earlier no longer hides the server failure that cut the step
short (it is described as a later failure instead).

Tests (`agent_jobs_test.zig`, each fails with its half of the fix reverted): `a failed read of
the runs' reports does not hold back a stop the runs already show (#142)`, `a failed read of the
node's assignments does not hold back a run's stop (#142)` (the list of `/assigned/<node>/`
fails) and `a failed write of the image summary does not hold back a run's stop (#142)`. The
failures go through `SwitchedStore.down_list_prefix` and `down_write_prefix` (test-only). Seed
2821617909 now passes.

Both lines are in `c1_regressions`. The f49041a line (`4242675264 145 4 --c1 --strong
--profile=partitions ...`) has the shape of the loading half: its next step failed on
`assigned`. It is a record, not a guard: it passes on ebfbac5 too, where that failure still
ended the step. #247 does not explain that (it covers failures inside the stages only); the
world the line draws changed between f49041a and ebfbac5, and the run no longer meets the cut
there. The unit test of the
assignments read is the guard.

## Still open (for the supervisor)

- If the read of `runs` itself keeps failing while keepalives succeed, the agent cannot know about
  the stop, and J6 has no bound. The tooth `sim-c1-teeth-job_runs_unread` shows it, and
  docs/decisions/2026-11-14-j6-runs-unread-gap.md sets out the two ways to close it for the
  owner.
- A step answers reads at its start's true time while its clock runs ahead (the coarseness noted
  above). That stretches the window between a stop committing and the next read by up to one
  step. It hides nothing in the safety direction, but it makes this class of failure easier to
  reach in the simulator than on a real host.

Where: `src/agent.zig` (`reconcile`, `Pass.load`, `Kept`), `src/agent_jobs.zig` (`pass`),
`src/agent_jobs_test.zig`, `src/sim_world.zig`, `build.zig` (`c1_regressions`).
