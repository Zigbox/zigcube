# B1 slice 2 review follow-ups: what was fixed and what waits

*Decided 2026-11-06, by the fix session of PR #106's review (supervisor relaying the owner).*

Fixed on `claude/b1-slice-2-followups`:

- `retention.exists()` reads `/jobs/<name>` for a job subject (absent: deleted, so its decisions
  go a day after the newest). Live jobs are not roots of the pinned set, so they cannot push the
  pass past `retention_pinned_max`. A live job's decisions follow the 7-day and 200 budgets; when
  slice 3 gives the job controller decisions that must outlive them, it adds roots for live jobs.
- `relay` and `placement` are skipped while parsing, only their presence is kept.
- Cancel compares `/job-status/<name>` (revision 0 if absent) with the job record.
- The `200` same-spec reply and the cancel replies carry the state from `/job-status/<name>`.
- A request body must arrive within `http_idle_timeout_ms` (state `reading`).

Left for later slices, now recorded here:

- **Slice 3:** the list filter `state=ended` (a group of terminal states) is not built; a list
  filter takes one state.
- **Slice 6:** `GET /v1/list` redacts `/jobs/` and `/job-input/` but not `/job-runs/`, whose `env`
  and input digest the read-only list shows. Redact it when runs are written (slice 3) or
  before B1 ships, whichever is first.

Where: `docs/decisions/2026-11-05-b1-slice-2-handoff.md` (the `exists()` note it carries is
superseded by the first item above), `docs/api.md`.
