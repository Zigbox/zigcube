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
- **Agent.** A refused report is dropped, not retried, and no longer fences at once: the agent
  cannot tell stale from tenure ended, so it has its lease checked on the next heartbeat
  (`renew_at_ms` brought forward by `agent_lease_check_ms`, one second), where a lost lease
  fences it. A refused `stopped` report of a run that is released, or placed again at another
  epoch, ends that run on the node: its start record is removed (`retire_if_stale`), so the
  refusal is not repeated on every pass. A `claiming` record of an unassigned run is removed
  too. Other writes under the tenure still fence at once.
- **Check.** sim-c1 J9 judges every stored `running` or `stopped` report; J10 (at rest) fails if
  a start record outlives its run's assignment. Tooth `sim-c1-teeth-job_stale` drops the
  assignment compare in the agent and in the server's handler; the stale reports arise from the
  run's real state, with no fabricated report.
- **Upgrade.** **Agents first, then the server.** An old agent fences (TERM, then KILL, of every
  container on the node) when its report is answered `applied: false`, and it never removes the
  record of a released run, so it reports it again, is refused again and fences again, for as
  long as it runs. So against a new server an old agent loops in a fence. A new agent against an
  old server is answered `applied: true`: the old server stores the stale report, which is
  harmless. Upgrade every agent before the server.
