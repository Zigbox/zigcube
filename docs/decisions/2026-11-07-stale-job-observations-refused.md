# A report of a retired or superseded run is refused at write time

Status: **adopted** (B2, 2026-11-07). It closes the last point of
[2026-11-07-job-name-reuse-incarnations.md](2026-11-07-job-name-reuse-incarnations.md), which stays
as written.

**Rule.** A `running` or `stopped` `JobObserved` is written only if `/assigned/<node>/<run>` is
still at the revision the report names (`assignment`). Both the server's `job-observed` POST and
the agent's own commit compare that key (`compare_sets.job_report`). A claim is unchanged: it has
its own compares (run, assignment, no observation).

- **Retired** (the run's assignment is released after its ending, or its job deleted): the key is
  absent, the compare fails, nothing is stored.
- **Superseded** (the run is placed again, or a reused name has a new run with a new assignment):
  the key is at another revision, same result.
- **Answer.** `200 {"applied": false}` while the tenure holds (the shape claims already use); a
  replaced tenure is still `503` ZC-E0510. No new code, bound or default.
- **Agent.** One invariant: a run is reported until its report is acknowledged or refused, then
  forgotten exactly once. The agent reports a run only under the assignment it reads in the same
  pass (`report_epoch`); a run with no assignment on this node (released, or its job removed by
  retention) is never reported, so no report can carry epoch 0. Such a run ends on the node: its
  container is stopped and, once the container has ended or is gone, its start record is removed;
  `enforce_deadlines` keeps working from the record until then. A refused report (the run was
  superseded between the read and the write) is dropped, not retried and counted
  (`job_reports_refused`); the next pass reads the assignment again and ends the run. A refusal
  neither fences nor moves the heartbeat: the agent cannot tell stale from tenure ended, and the
  heartbeat finds a tenure that ended on its own schedule. A `claiming` record of an unassigned
  run is removed too. Other writes under the tenure still fence at once.
- **Check.** sim-c1 J9 judges every stored `running` or `stopped` report; J10 (at rest) fails if
  a start record outlives its run's assignment, and, after the cluster heals, if any node makes
  more than `job_refusals_after_heal_per_node_max` (8) refused reports: a run that is reported
  again and again after its refusal fails it. Tooth `sim-c1-teeth-job_stale` drops both
  defences: the agent reports a run it no longer holds under the assignment it was started
  under, and neither the agent nor the server's handler compares the assignment; the stale
  reports arise from the run's real state, with no fabricated report. sim-c1 J10 and seed 240's
  replay (`zig build sim-c1-regressions`) fail with the agent fix reverted.
- **Upgrade.** **Agents first, then the server.** An old agent fences (TERM, then KILL, of every
  container on the node) when its report is answered `applied: false`, and it never removes the
  record of a released run, so it reports it again, is refused again and fences again, for as
  long as it runs. So against a new server an old agent loops in a fence. A new agent against an
  old server is answered `applied: true`: the old server stores the stale report, which is
  harmless. Upgrade every agent before the server.
