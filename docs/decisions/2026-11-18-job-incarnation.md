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
   so retention waits until that release. The wait has no bound of its own: `release_run` returns
   without releasing while the node's allocation is unaccounted or would underflow, and the
   allocation auditor then holds an open finding on the node (`/audit/allocations/<node>`,
   `zcube status`). `zcube why job` says why an ended job is kept ("kept while its run is still
   assigned to <node>: the scheduler has not released it", and names the auditor's finding when
   there is one). A bound would change retention's user-visible behaviour and is left to the
   owner.
2. **An assignment names its incarnation.** `Assigned.run_created` is the `create_revision` of the
   `/job-runs/<name>` record (records.zig's `job_run_key`) the scheduler placed. The scheduler's
   placement compares that record, so the value is the one it read. The job controller reads a
   run's assignment only through `World.placement(run)`, which treats an assignment that names
   another `create_revision` as absent, and so does one whose own `mod_revision` is lower than
   that record's `create_revision` (`records.assignment_is_stale`): a run is placed after it is
   created and never moved, so an older assignment was left by an earlier job of the name. That
   rule needs no stored field and holds for assignments any server version wrote. That covers marking the run placed, a claim, a report's
   admission (`admissible`), the stop and the ending, so nothing an old incarnation left moves the
   new run. The new run then ends `not_started` at its `start_by_ms`, and its terminal status
   lets the scheduler release the old assignment.
3. **What the agent sends is unchanged; the agent API and the agent refuse a stale claim.** A
   claim or report carries `assignment`, the revision of the assignment it ran under. The
   assignment carries the incarnation, so the report names it transitively. The ending is written
   by the job controller from an admitted report, and an admitted report's assignment names this
   incarnation. A claim is written by the agent API itself, so it applies the same revision rule:
   a claim whose `assignment` is older than the run record it names is refused as any failed
   compare is (`applied: false`, which every agent version reads as "read again"), and a node's
   job input and job certificate are not given under such an assignment (ZC-E0133, cause "an
   earlier job of that name left it"). The agent also stops claiming under a stale epoch
   (`agent_jobs.claim`, the rule it already used for its containers). No new field goes on the
   agent API and no new code is registered, so agents of every version are covered: an old agent
   is refused at the API, a new one does not ask.

## Gaps

- An assignment written by an older server has no `run_created`; the revision rule of decision 2
  still judges it, so a run placed before the upgrade is covered too. `run_created` is kept as a
  second witness the store's revisions do not depend on.
- The deterministic regression tests replay both traces of the model:
  `job_controller_test.zig`, "a reused job name never takes the old run's assignment or reports
  (#243)" (with `placement` ignoring `run_created` it fails as the model found: the new job goes
  `running` on the old assignment's claim), and `job_retention.zig`, "an old job whose run is
  still assigned stays until the release (#243)".

## Simulator tooth

The reuse world (`sim-c1-reuse`) deletes ended jobs through `job_retention.prune`, but the
scheduler released every terminal run before a jump, so no assignment survived to meet a reused
name and a first tooth caught 0 of 60 seeds. The world now holds the scheduler's releases from the
create before each jump to the reuse after it (jumps fall on every third create;
`Scheduler.runs_held`, which has effect only in that world, so a server never holds), which is the
outage the model assumes. The report counts the jobs retention kept
(`held assigned=..`).

`c1_teeth.job_reuse_assigned` turns off every part: `mark_assigned` is skipped,
`World.placement` takes any incarnation's assignment, and neither the agent API nor the agent
applies the revision rule. The agent then starts the new run under the
old assignment while its container still runs, so under this tooth only `SimRuntime.start_impl`
and `sim_node.make_room` let a running container be replaced under the same name (outside it the
asserts stand). Measured 2026-11-18, 300 operations, `--c1`: 7 of seeds 1..60 fail, J2 at 33 36 39
44 57 59 and J4 at 40; with the fix all 60 pass (`sim-c1-reuse`), and `sim-c1-teeth-job_reuse`
still fails J11. With retention's wait alone off (the tooth's runner built with the job
controller's, the agent API's and the agent's checks on), the seven seeds all pass, each with
`held assigned=0` and reused creates that met a container: the revision rule holds J2 and J4 by
itself, as the review asked (before it, the same measurement failed J2 at all seven).
`sim-c1-teeth-job_reuse_assigned` runs seeds 30..60 (stopping at 33) and seed 40
alone; the fleet canary runs 180 fresh seeds (miss probability 0.883^180, about 2e-10).
