# The job ending's dedupe key is adopted: `(name, epoch)`, or `(name, ended_at_ms)` if unplaced

Status: **adopted** (supervisor, 2026-11-06), after the review of PR 144. It settles the proposal
of [2026-11-06-job-watch-dedupe-key.md](2026-11-06-job-watch-dedupe-key.md), which stays as
written; where they differ, this file wins.

- The key of a job ending is `(name, epoch)` when `epoch` is present and non-zero. `epoch` is a
  store revision, so it is unique per placed ending, and it is on every row and event of every
  server. Otherwise (an unplaced ending: cancelled before a claim) the key is
  `(name, ended_at_ms)`, the only thing that tells two endings of a name reused after retention
  apart. An absent `epoch` counts as none, an absent `ended_at_ms` as 0.
- The first draft keyed every ending on `(name, epoch, ended_at_ms)` and said an older server's
  row, lacking `ended_at_ms`, "falls back to `(name, epoch)`". That was wrong: watch events
  already carried `ended_at_ms` inside `status`, so a client would key an ending `(a, 3, 900)`
  from an event and `(a, 3, 0)` from a row, and print it twice. The reviewer's option 2 is the
  fix: a placed ending never depends on `ended_at_ms`, so it works against any server.
- `ended_at_ms` is the member the job's status already stores (`records.JobStatus`, set when the
  job reaches a terminal state and never changed; J3 checks it). It is also a member of the list
  row (`GET /v1/jobs`, additive). No stored value and no `Store` key changes.
- `zcube job watch` (`src/cli_job.zig`) and J4 (`src/sim_jobs_watch.zig`) dedupe on this key;
  `docs/api.md` and `docs/briefs/b1.md` say so. The CLI hashes name, epoch and time through one
  hasher.
- J4 also checks the exactly-once half: an ending that matches a handled one on `(name, epoch)`
  with `epoch != 0` but another `ended_at_ms` is a violation (one ending under two keys), and the
  end-of-run coverage compares to the last member.
- No bound or default changes.

## What J4 still does not do

J4's workload names every job `jb-<n>` once, so no run reuses a name, and no simulated run
produces two unplaced endings of one name; the collision is covered by the `Seen` unit test in
`src/cli_job.zig`. Reusing a name needs the ended job to be dropped by retention first, which
takes `job_finished_age_ms_min` (1 h) of sim time. The manual clock passes it only in 100 ms
ticks (36,000 ticks per reuse, each driving every node), or by a jump that expires every lease and
fence and makes the J1, J6 and J8 windows meaningless. That is too costly for a change that must
not alter any bound; left for a retention-focused slice.
