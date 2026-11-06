# The job ending's dedupe key is adopted: `(name, epoch, ended_at_ms)`

Status: **adopted** (supervisor, 2026-11-06). It adopts the proposal of
[2026-11-06-job-watch-dedupe-key.md](2026-11-06-job-watch-dedupe-key.md), which stays as written.

- The key of a job ending is `(name, epoch, ended_at_ms)`; an absent `epoch` counts as none.
- `ended_at_ms` is the member the job's status already stores (`records.JobStatus`, set when the
  job reaches a terminal state and never changed; J3 checks it). It is now also a member of the
  list row (`GET /v1/jobs`, additive). `GET /v1/jobs/{name}` and watch events already carried it
  inside `status`. So no stored value and no `Store` key changes.
- `zcube job watch` and J4 (`src/sim_jobs_watch.zig`) dedupe on the new key; `docs/api.md` says so.
- No bound or default changes. An older server's rows lack the member; a client reads that as 0
  and falls back to `(name, epoch)`, as before.
