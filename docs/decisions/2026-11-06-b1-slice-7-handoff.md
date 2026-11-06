# B1 slice 7 handoff: the `zcube job` CLI

Date: 2026-11-06. Branch `claude/b1-slice-7`, stacked on slice 6 (#139).

## Decisions

- **Exit codes 10, 11, 12** for `job get --wait` (exited otherwise, failed, cancelled) are the
  brief's; they are constants (`exit_job_*`) and travel in `Report.outcome` when nothing failed.
- **Polling, not holds, for `--wait`**: once a second (`cli_job_poll_ms`). `job watch` holds the
  server's watch for 20 s (`cli_job_watch_hold_ms`). Both are new CLI-internal constants, not
  changes of an existing bound.
- **Secrets**: env by name only; input as "N bytes, given as VAR". `command_line()` blanks `--env`
  values, so the failure record and bundles cannot carry them. `bundle` of a job reads
  `/v1/job-status/<name>`, not `/v1/jobs/<name>` (that holds env values and the input).
- **`--command` ends option parsing** and takes the rest of the line (at most `cli_args_max` = 64
  words).
- **Input file**: UTF-8, at most 64 KiB, else `ZC-E0111`; unreadable is `ZC-E0109` (reworded to cover any file; see
  2026-11-06-e0109-covers-input-files.md).
- **Watch resume**: head start via `/v1/jobs?limit=1`; on 410 `ZC-E0203` it relists
  `state=ended` (paged with `at`/`continue`), dedupes by (name, epoch) and continues from the
  list's revision. Private bounds: 1,024 pages (`ZC-E0103` beyond) and 8,192 hashed keys
  (`job_admitted_window_max`), so a relist never prints an ending twice. A 410 during relist paging
  restarts the listing (8 times at most). Rows carry no revision, so a relist also prints endings
  from before `--from`.
- Golden harness: for `job` cases the style flags go before the args (`--command` would swallow
  them). E0130-E0134 now use job commands; their verbose goldens changed accordingly.

## Traps

- `Client.send` fails on non-2xx; `attempt` returns any status; `fail` relays a reply as the error.
- `watch` runs on the env arena, which grows during a long watch (never freed).
- A job cancelled before it ran ends `cancelled`, which lets the live test run without an agent.

## Not run / next

- `job logs` is out of scope (slice 8 cut). Slice 10 and demo-b1 should script `job run`,
  `get --wait` and `watch` against agents; the live test here uses no agent.
