# A run's assignment names its incarnation, and retention waits for its release (#243)

Date: 2026-11-18. Issue #243 (the TLA+ jobs model, findings `job-reuse-assigned` and
`job-reuse-report`).

## Problem

A job's run id is a function of its name (`<name>-job`), so the `/assigned/<node>/<name>-job`
record of one job and of a job created again under the same name are the same key. Retention's
`drop_job` deleted an ended job's records without looking at that key. If the scheduler had not
released the assignment (it was down, or `release_run` returned early on an unaccounted
allocation), the name was free again with the old assignment still in the store, and:

- the agent claimed the new run under the old assignment and restarted it every pass, while its
  status stayed `running` and no deadline fired (J2);
- the agent re-reported the old run's ending, `admissible` accepted it because it compares nothing
  about the run, and the new job went to `exited` without starting (J11).

Nothing heals that state.

## Decision

1. **Retention waits.** A pass lists `/assigned/` at the revision it read the statuses at and
   keeps every ended job whose run has an assignment, on any node (`Ended.assigned`, counted in
   `Cursor.held_assigned`). A list cut at `pages_max` keeps every job. No assignment of an ended
   run can appear after the read: a placement compares the job's status at a pending revision, and
   `drop_job` compares the status it read. The scheduler releases a run whose status is terminal,
   so retention waits at most until that release.
2. **An assignment names its incarnation.** `Assigned.run_created` is the `create_revision` of the
   `/job-runs/<name>` record (records.zig's `job_run_key`) the scheduler placed. The scheduler's
   placement compares that record, so the value is the one it read. The job controller reads a
   run's assignment only through `World.placement(run)`, which treats an assignment that names
   another `create_revision` as absent. That covers marking the run placed, a claim, a report's
   admission (`admissible`), the stop and the ending, so nothing an old incarnation left moves the
   new run. The new run then ends `not_started` at its `start_by_ms`, and its terminal status
   lets the scheduler release the old assignment.
3. **What the agent sends is unchanged.** A claim or report carries `assignment`, the revision of
   the assignment it ran under. The assignment carries the incarnation, so the report names it
   transitively. The ending is written by the job controller from an admitted report, and an
   admitted report's assignment names this incarnation. No new field goes on the agent API, and
   agents of every version are covered.

## Gaps

- An assignment written by an older server has no `run_created` and is taken as before. Decision 1
  (retention) is what protects a run placed before the upgrade.
- The deterministic regression tests replay both traces of the model:
  `job_controller_test.zig`, "a reused job name never takes the old run's assignment or reports
  (#243)" (with `placement` ignoring `run_created` it fails as the model found: the new job goes
  `running` on the old assignment's claim), and `job_retention.zig`, "an old job whose run is
  still assigned stays until the release (#243)".

## Simulator tooth

The reuse world (`sim-c1-reuse`) deletes ended jobs through `job_retention.prune`, but the
scheduler released every terminal run before a jump, so no assignment survived to meet a reused
name and a first tooth caught 0 of 60 seeds. The world now holds the scheduler's releases from the
create before every third jump to the reuse after it (`Scheduler.runs_held`, sim only; the server
never sets it), which is the outage the model assumes. The report counts the jobs retention kept
(`held assigned=..`).

`c1_teeth.job_reuse_assigned` turns off both halves: `mark_assigned` is skipped and
`World.placement` takes any incarnation's assignment. The agent then starts the new run under the
old assignment while its container still runs, so under this tooth only `SimRuntime.start_impl`
and `sim_node.make_room` let a running container be replaced under the same name (outside it the
asserts stand). Measured 2026-11-18, 300 operations, `--c1`: 7 of seeds 1..60 fail, J2 at 33 36 39
44 57 59 and J4 at 40; with the fix all 60 pass (`sim-c1-reuse`), and `sim-c1-teeth-job_reuse`
still fails J11. `sim-c1-teeth-job_reuse_assigned` runs seeds 30..60 (stopping at 33) and seed 40
alone; the fleet canary runs 180 fresh seeds (miss probability 0.883^180, about 2e-10).
