# `why job` reads job records in its desired and observed steps

Date: 2026-11-06. Review 5802009368 on PR #133 found that `zcube why job` failed for most jobs.

## Decision

`src/why.zig` `desired_step` read every cited desired key that was not `/replicas/` or `/jobs/` as
a `records.Service`, so a chain that cited `/job-runs/<name>` or `/assigned/<node>/<run>` returned
ZC-E0301 ("not a valid service record") and the whole chain failed (API, CLI, console). It now
reads `/job-runs/` as a `JobRun` ("run train-job of job train is desired: deadline 60000 ms", with
", stopped" once `stop` is set) and `/assigned/` as an `Assigned` ("run train-job is assigned to
node1"). A record that is not what its prefix says is still ZC-E0301. `observed_step` had the same
flaw for `/job-observed/<node>/<name>` (the cause of `job_running`, and of an `end_job` with an
agent report): it now reads a `JobObserved` ("train-job on node1: stopped (ran out of memory)") and
shows its diagnostic. No API, key or record change.

Tests (`src/why.zig`, "why job: ..."): pending (`hold_pending` -> run), placed (`job_placed` ->
assignment), running (`job_running` -> report), the endings with a report (exited, oom, deadline
signal, lost), the endings with none (cancelled, deadline, unreachable before a claim, each citing
the desired run), a `stop_job` citing `/jobs/`, and a malformed run. Each asserts the chain, and
disabling the new branches fails them with Malformed.

## Traps

- **An end with no agent report cites the desired run, not `stop_job`.** `Pass.end` cites
  `/job-runs/<name>`; the earlier `stop_job` is a decision of its own and is not a link of the end's
  chain. The console mock cited it; it now matches the server, and `tools/browser_check.mjs` asserts
  the chain does not contain `stop_job`.
- **Core tests run under `zig build wasm-test`, not `zig build test`.** `-Dtest-filter` is ignored
  there (all core tests run; read the log for `why job`), and a filter that matches a core test
  under `zig build test` passes without running it.
- The mock still words a `/job-observed/` step in its own way ("stopped for cancel", "exited on
  signal 9") rather than the server's `exit_text`; it is not asserted against the server.
- A desired step reads the record at the cited revision; the mock reads it now, so its `, stopped`
  can show on a step the server would word without it.
