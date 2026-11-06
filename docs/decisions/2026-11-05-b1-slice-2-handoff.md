# B1 slice 2 (the job API): what the next slice needs to know

Status: handoff note, 2026-11-05.

- `src/job_api.zig` (core) holds create, get, list and cancel; `src/api.zig` routes them
  (`/v1/jobs`, `/v1/jobs/{name}`, `/v1/jobs/{name}/cancel`) and now carries a `status` in its
  `Reply` and `Response` (201, 202). `POST /v1/jobs` is the only route over 64 KiB
  (`job_request_bytes_max`, `server_http.read_body`); `server_test.zig` posts a worst-case input
  through a real socket.
- The API writes `/jobs/<name>`, `/job-input/<name>` (base64) and `/job-admission` in one batch,
  with a decision `submit` (`cancel` for a cancel). The controller's `job-created` decision is
  separate. `/job-endings` is read, never written, here: the job controller (slice 3) must
  increment `ended` when a job ends or `jobs_max` will count it for ever.
- The window of `/job-admission` has at most 74 hour entries; the hour is `now_ms / 3_600_000`.
- `retention.exists()` answers `true` for a job subject: the snapshot holds no jobs yet, so a
  decision of a removed job is never pruned as "subject gone". The retention slice must decide
  that.
- `why job` reads `/jobs/<name>` and `/job-status/<name>` directly (`why.job_state`).
- The read-only `GET /v1/list` redacts the `env` of `/jobs/` and the `base64` of `/job-input/`.
  The writing token and, until identity lands, the agent endpoints see them (docs/api.md).
- A list filter keeps a subset of a store page; `continue` follows the store's pages.
