# B1 slice 3 handoff

Done: scheduler `place_run` / `release_run`; `assigned_max` bounds on `/assigned/` lists;
`src/job_controller.zig`: creates runs once (`job_created`, judged per incarnation), two-phase
endings, admissible reports, a claim judged by its tenure and the grace (never ended as unstarted),
paged reads (`job_controller_page_max` jobs per page, a bounded arena per page, a cursor across
steps), store-derived idempotence (no in-memory `noted` ring), W0307 `drop_report`, exit table
`map_ending`; wired into `control_plane.zig` (decision-id instance `0xC000 + (instance & 0x3fff)`);
`GET /v1/jobs?state=ended` (tested); `/job-runs/` env and input digest redacted for read-only
tokens in `GET /v1/list`. Decision actions are snake_case (keys.md, authority.md section 7).

Review fixes (PR 112): `release_run` keys on the job being gone (no status and no run) or a
terminal status, never on a missing status alone; the relay parse test runs in its own arena and
asserts `queryCapacity() <= request_arena_bytes_max`; the body-read floor (about 40 KB/s) is in
docs/api.md, and the idle deadline stays as it is (the option the slice 2 follow-ups allow).

**A behaviour change for replicas:** `judge` now refuses a node that holds
`runtime_handles_max` assignments in all (`handles_full`), and the count includes runs, so a node
full of runs takes no replica either.

Cut (not done), each with its reason and slice:
- sim-c1 negative test for `job_created`: the simulator has no job workload yet. Slice 5
  (`2026-11-06-b1-sim-c1-negative-test-moves-to-slice-5.md`).
- Retention pin-roots test with jobs: not required here, because this slice adds no job roots to
  retention (retention reads `/jobs/` and `/job-status/` only through its slice 1 rule). The slice
  that adds job roots to retention (slice 4) owns it.
- Body idle deadline in `server_http.zig`: replaced by the stated floor in docs/api.md.

Traps: the `seen` table (loss grace for a tenure with no `lost` judgement) is forgotten on
restart, so that grace restarts. A malformed `/job-status/` fails the scheduler pass loudly, on
purpose.
