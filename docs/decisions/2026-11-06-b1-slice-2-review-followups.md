# B1 slice 2 review follow-ups: what was fixed and what waits

*Decided 2026-11-06, by the fix session of PR #106's review (supervisor relaying the owner).*

Fixed on `claude/b1-slice-2-followups`:

- `retention.exists()` reads `/jobs/<name>` for a job subject (absent: deleted, so its decisions
  go a day after the newest). Job subjects were never roots of the pinned set (roots come only
  from the snapshot's services, replicas and nodes), so the old `.job => true` never risked
  `retention_pinned_max`: it kept a removed job's decisions for 7 days instead of 1. The test's
  `pins_max = 2` half runs on an empty snapshot and proves nothing. A live job's decisions follow
  the 7-day and 200 budgets; when slice 3 adds roots for live jobs, it tests the cap with a
  snapshot or root source that has jobs.
- `relay` and `placement` are skipped while parsing, only their presence is kept.
- Cancel compares `/job-status/<name>` (revision 0 if absent) with the job record.
- The `200` same-spec reply and the cancel replies carry the state from `/job-status/<name>`.
- A request body must arrive within `http_idle_timeout_ms` (state `reading`).

Left for later slices, now recorded here:

- **Slice 3:** the list filter `state=ended` (a group of terminal states) is not built; a list
  filter takes one state.
- **Slice 3:** `GET /v1/list` redacts `/jobs/` and `/job-input/` but not `/job-runs/`, whose `env`
  and input digest the read-only list shows. Redact it in the slice that first writes runs.
- **Slice 3:** the `relay` parse test has no teeth: the rig's arena is uncapped, so a parse that
  builds a `std.json.Value` again would pass. Run it in its own arena and assert
  `queryCapacity() <= constants.request_arena_bytes_max`.
- **Slice 3:** the body deadline (`http_idle_timeout_ms`, 10 s) covers the whole body, so a
  maximal `POST /v1/jobs` needs about 40 KB/s; a slower client is cut with no code. Make it an
  idle deadline between reads with an overall cap scaled to the length, or state the floor in
  `docs/api.md`.

The slice 3 items and the corrected retention note come from PR #108's review.

Where: `docs/decisions/2026-11-05-b1-slice-2-handoff.md` (the `exists()` note it carries is
superseded by the first item above), `docs/api.md`.
