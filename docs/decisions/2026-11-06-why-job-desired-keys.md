# `why job` reads job records in its desired and observed steps

Date: 2026-11-06. Review 5802009368 on PR #133 found that `zcube why job` failed for most jobs.

## Decision

`src/why.zig` `desired_step` read every cited desired key that was not `/replicas/` or `/jobs/` as
a `records.Service`, so a chain that cited `/job-runs/<name>` or `/assigned/<node>/<run>` returned
ZC-E0301 ("not a valid service record") and the whole chain failed (API, CLI, console). It now
reads `/job-runs/` as a `JobRun` ("run train-job of job train was created: deadline 60000 ms",
with ", stopped" once `stop` is set) and says of any other key that is not a service ("/assigned/
node1/train-job exists"). A record under `/replicas/`, `/jobs/`, `/job-runs/` or `/services/` that is not what its prefix says
is still ZC-E0301; a key under any other prefix (`/assigned/...`) is never read, so a corrupt one
renders "exists" too.
`observed_step` had the same flaw for `/job-observed/<node>/<name>` (the cause of `job_running`,
and of an `end_job` with an agent report): it reads a `JobObserved` ("train-job on node1:
running") and shows its diagnostic. B1 slice 5 (#127) landed the same fix while this branch was
open; the merge kept slice 5's code and wording, and this change adds the tests, the mock and the
docs. No API, key or record change.

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
- **`-Dtest-filter` drops the core tests from `zig build test`.** An unfiltered `zig build test`
  runs them: `tests.zig` imports `core.zig`, and its named test "every core module's tests are in
  this root" brings in `why.zig`'s. A filter that does not match that test drops the import, so
  `-Dtest-filter="why job"` runs only the shell's tests and passes. Filter on both
  (`-Dtest-filter="why job" -Dtest-filter="every core module"`) or read `zig build wasm-test`.
- A job whose node is lost (`failed unreachable`, no agent report, no stop on the run) ends its
  chain at `/job-runs/<name>` ("run train-job of job train was created: ..."); the answer to
  "why" is the decision above it (action and reason). Tested in `why.zig`; no API change.
- A desired step reads the record at the cited revision; the mock reads it now, so its `, stopped`
  can show on a step the server would word without it.
