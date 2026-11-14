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
waits for as long as that goes on. #247 fixed the same problem for failures before the pass and
inside its loop. This read, between the two, was left out.

## Fix

A failed read of the reports is kept (`Kept.stage`), as #247 keeps an earlier stage's failure:
the pass has no reports and makes no write, and every subject goes through `stop_only` from the
runs it read. The bounds do not change. Test: `a failed read of the runs' reports does not hold
back a stop the runs already show (#142)` (`agent_jobs_test.zig`) fails the list once through
`SwitchedStore.down_list_prefix` (test-only). It fails without the fix. Seed 2821617909 now
passes, with the worst stop at 5,514 ms.

The f49041a line (`4242675264 145 4 --c1 --strong --profile=partitions ...`) has the same shape,
but its next step failed on `assigned`, before the pass. That is #247's case: it fails on
f49041a and passes on ebfbac5 without this change. Both lines are in `c1_regressions`.

## Still open (for the supervisor)

- If the read of `runs` itself keeps failing while keepalives succeed, the agent cannot know about
  the stop. J6's fenced term assumes that renewals stop when reads do. This fix does not change
  that, and no seed has shown it yet. Ways to close it, if wanted: renew only after the step's
  `runs` read succeeds, or have the fence count a run of failed reads. Either one changes the
  fence's behaviour, so it is for the owner to decide.
- A step answers reads at its start's true time while its clock runs ahead (the coarseness noted
  above). That stretches the window between a stop committing and the next read by up to one
  step. It hides nothing in the safety direction, but it makes this class of failure easier to
  reach in the simulator than on a real host.

Where: `src/agent_jobs.zig` (`pass`), `src/agent_jobs_test.zig`, `src/sim_world.zig`,
`build.zig` (`c1_regressions`).
