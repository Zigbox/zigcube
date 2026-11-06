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

## Review fixes (review 5796099523)

- Restart table gap: a `claiming` start record with our own `claimed` observation (current tenure,
  this epoch, run served, no stop) now writes `claimed` and starts, still at most once. This is the
  claim applied with the reply lost, and a crash between the claim and the record write; both leave
  the same state, so the tests build that state directly rather than through `sim_net`. Under an
  older tenure or with a stop the run is `stopped` with `stop_cause` `not_started`, never `lost`.
  A `claiming` record with no observation and no assignment is removed.
- The input is fetched before the `claimed` record is written. A store or transport error leaves the run
  claimed and not started, and a later pass retries. Only a digest mismatch or a server saying the
  input is absent (ZC-E0523 from the input endpoint) ends it, as `start_failed`.
- ZC-E0523 is new, proposed in `2026-11-06-zc-e0523-job-input-digest.md`. A refused spec is ZC-E0130 with
  the runtime's `spec_problem`.
- ZC-W0503 is raised for `stop_cause == .deadline`. A stop for a run the server no longer serves records
  `unreachable` first, and uses the run's `grace_ms` from the start record.
- E0521/E0522 are built by one function each, which the golden test also calls.
- Slice 5 must run agents through the endpoint, not `sim_world`'s direct-store shape: the
  E0523-to-absent mapping and the HTTP statuses are covered only by the api, client and smoke tests.

## Cut

- Retention of `/job-observed/` records (slice 6).
- A watch prefix for `/job-runs/`: a stop is picked up by the 1 s resync, not at once.
- The cluster simulation of jobs (slice 5).
- ZC-W0307 (a dropped report) is raised by slice 3, so it is not a cut here.

## Proposed new codes

ZC-E0523, a run's input does not match its digest; see the decision record.
