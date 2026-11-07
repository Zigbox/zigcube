# A reused job name is told from the job before it by the run record's create revision

Status: **adopted** (B1 release fix session, 2026-11-07). It refines the retention-then-reuse
behaviour that [2026-11-06-job-dedupe-key-adopted.md](2026-11-06-job-dedupe-key-adopted.md) relies
on; that file stays as written.

A run id is `<name>-job`, so a name reused after retention shares its id with the job that is gone.
The release review (PR 147, MUST 2) found a leftover `stopped` observation, start record or
container of the gone job making a node refuse to claim the new one, or adopt the old one.

- **Identity is the `/job-runs/<name>` create revision.** It is fixed for a job's life, and every
  assignment, claim, start record and container of that job is later than it. The assignment epoch
  cannot serve: one job is re-assigned under new epochs, and its old claim must stay a claim
  (`a claim left under an older epoch is not started under the new assignment`).
- The agent treats an observation (`assignment`), a start record (`epoch`) or a container
  (`zcube.created`) older than the served run's create revision as a leftover: the observation and
  start record are ignored (the claim replaces the observation, `observed_revision`), a running
  leftover container is stopped, and none is adopted.
- The server accepts `observed_revision` on a claim only for an observation made under an
  assignment older than the run's creation, so the at-most-once claim is still enforced there.
- The agent's run listing reads the node's assignments and each run by key (MUST 1), and the
  node's observation list is bounded by `job_admitted_window_max`, the existing bound on retained
  runs. No bound, default or code changes.
- Not done: a stale observation is still written when an old agent returns late (the write
  compares the tenure only); it is now harmless, and retention deleting it is B2.
