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
  (`renew_at_ms = 0`), where a lost lease fences it. Other writes under the tenure still fence at
  once.
- **Check.** sim-c1 J9 judges every stored `running` or `stopped` report; tooth
  `sim-c1-teeth-job_stale` drops the agent's compare.
- **Upgrade.** Server first, as for #148: an older server stores the stale report, which is
  harmless.
