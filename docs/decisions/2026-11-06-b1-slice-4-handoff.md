# B1 slice 4 handoff: agent runs, claim-then-start, adoption

Date: 2026-11-06. Branch `claude/b1-slice-4`, stacked on `claude/b1-slice-3` (PR #112).

## What is built

- `src/agent_jobs.zig`: one pass of `Agent.reconcile`, after the replicas. The wanted set is the node's
  assigned entries with a job; claim, then start; the start record `jobs/<run>.json`; the
  monotonic deadline compared only under the same `boot_id`; `stop_cause` written before the signal;
  fence reports under the next tenure (`note_fence`); adoption after `kill -9`.
- `src/agent_api.zig`, `src/agent_client.zig`: `runs`, `runs/{name}/input`, `job-observed` (GET, POST).
  `docs/api.md`, `docs/agent.md` ("Runs") describe them.
- Tests: `agent_jobs_test.zig` (simulation world, 12), `agent_api_test.zig` (4), `agent_client_test.zig`
  (2). `agent-smoke` has a job step.
- Mutations proved: removing the `run.stop != null` guard fails "stop never claimed"; removing the
  `note_fence` call fails "fence is recorded under the next tenure".

## Decisions and traps

- Run id is `<name>-job`; the container name is the run id; labels `zcube.replica` (run id) and
  `zcube.job`. The fake runtime's `faults/<name>` files therefore work for a run by its id; no code.
- A failed claim compare under a live tenure is `200 {"applied":false}`; an ended tenure is `503`
  ZC-E0510, which `RemoteStore` returns as `succeeded=false` like the replica paths.
- `sim_world` uses the store directly, so the HTTP mapping is covered by the api, client and smoke tests only.
- The job's `running` state can be set by the claim before `Runtime.start` returns: wait for the
  container, not the state, when a test counts processes (the smoke did this wrong once).
- `zig build test` run through a tool with a 120 s timeout is cut off and reports a failed command
  with no test name; run the test binary directly to see the result.

## Cut

- ZC-W0307 (a dropped report) is not raised.
- Retention of `/job-observed/` records (slice 6).
- A watch prefix for `/job-runs/`: a stop is picked up by the 1 s resync, not at once.
- The cluster simulation of jobs (slice 5).
- `Agent` quirk: `claim` has an unused `existing` parameter.

## Proposed new codes

None. "The input could not be fetched, or its digest did not match" uses ZC-E0301 (via
`raise_malformed`), the closest; the owner may want a code of its own.
