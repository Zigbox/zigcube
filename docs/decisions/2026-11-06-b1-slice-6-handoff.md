# B1 slice 6 handoff: jobs watch, retention and J4

Status: handoff note for the next implementer.

## What was built

- `GET /v1/jobs/watch` (`src/job_api.zig`, `src/api.zig`): `/v1/watch` over `/job-status/`, values
  decoded to job statuses, 410 `ZC-E0203` under compaction, `label=k=v` filter.
- Age retention (`src/job_retention.zig`, run from `JobController.reconcile`): oldest first, in
  batches of `retention_batch_pairs`, never a job younger than `job_finished_age_ms_min`, input
  deleted at the end, names free again.
- J4 (`src/sim_jobs_watch.zig`, `watch_client` in `src/sim_cluster.zig`) and the `job_gap` tooth.
- J6 and J8 tightened as the supervisor asked: J6 subtracts only wedged time after the stop; J8's
  fence allowance counts only link cuts and wedges after the deadline (or within `ttl - margin`
  before it); `Node.call_failed` counts remote-call failures only, not local runtime failures.
- A Rig test for the refused claim (`src/agent_jobs_test.zig`, via `SwitchedStore.before_put`).

## Decisions

- The name `watch` is reserved (`ZC-E0130`), because `/v1/jobs/watch` shares the path shape.
- Job list rows gain an additive `epoch` so a client can deduplicate by `(name, epoch)`.
- A label-filtered watch drops deletes.
- Retention lives in `JobController`, not a separate control-plane field.

## Deviations and gaps

- The simulation reaches 410 through its own 60 s compaction to head, harsher than the server's
  keep window, so the real keep window is not exercised by J4.
- Retention is not simulated: runs are minutes long, below the 1 h floor. It has 4 unit tests.
- Not done: J1's tenure half and J3's "deleted status not recreated while its job exists".
  Delete-while-job-exists is already caught by `status_orphaned`. A put of `/job-status/<name>`
  with no `/jobs/<name>` is the candidate J3 check, but J1's "at most one tenure" meaning is not
  settled in the brief (b1.md around lines 236-245, 292, 430). Left for slice 7 or a decision.
- Retention now removes `/job-observed/<node>/<name>` on every node (review of #139). It still
  rescans every status per pass (O(N^2/8) reads for a backlog of N): known cost, not fixed.
- The sim client's kill only pauses between polls; not fixed.
- The dedupe key for unplaced endings: `2026-11-06-job-watch-dedupe-key.md`.

## Teeth rates (`--seeds 1..40 100 --c1`)

| tooth | profile | failed of 40 |
|---|---|---|
| `job_gap` | mixed | 20 (5 of 1..10) |
| `job_deadline_late` | mixed / slow_store | 25 / 32 |
| `job_deadline` | mixed / slow_store | 25 / 32 |

`sim_cluster --seeds 1..200 200 --c1`: 0 of 200 failed.
