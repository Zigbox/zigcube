# B1 slice 3 handoff

Done: scheduler `place_run` / `release_run`; `assigned_max` bounds on `/assigned/` lists;
`src/job_controller.zig` (creates runs once, `job-created` rule, two-phase endings, admissible
reports, grace for lost nodes, exit table `map_ending`) with 12 unit tests; wired into
`control_plane.zig` (decision-id instance `0xC000 + (instance & 0x3fff)`); `GET /v1/jobs?state=ended`;
`/job-runs/` env and input digest redacted for read-only tokens in `GET /v1/list`.

Cut (not done), for a following slice:
- W0307 (dropped report) is never recorded.
- No sim-c1 negative test for the job-created rule (the unit test exists).
- Relay parse test arena assertion; body idle deadline in `server_http.zig` (floor is about
  40 KB/s with the 10 s `http_idle_timeout_ms`; not yet in docs/api.md); retention pin-roots test
  with jobs; `GET /v1/jobs?state=ended` has no dedicated test.
- authority.md section 7 and keys.md not updated for the job decision actions.

Traps: `/jobs/` is read whole (`list_all(jobs_max)`, arena 16 MiB), not paged. The `noted` and
`seen` rings are forgotten on restart (a contradiction is re-recorded once; loss grace restarts).
A malformed `/job-status/` fails the scheduler pass loudly, on purpose.
