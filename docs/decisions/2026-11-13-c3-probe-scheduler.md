# C3 slice 9: how the agent schedules health checks

*Decided 2026-11-13, by the slice (C3 slice 9); the cap is provisional until the supervisor confirms it.*

- **At most 8 checks in flight per node** (`probes_concurrent_max`, a new constant). A real check
  is an exec in a guest (slice 10), and a node with many checked replicas should not start them
  all in one step. The due checks go in order of due time, then replica name, so none starves.
  Provisional: a user-visible limit, for the supervisor to confirm or change.
- **In memory only.** The counts and verdicts are not written to the state directory. A
  restarted agent reports `unknown` until the checks settle the verdict again, which the brief
  asks for and which no stale verdict can contradict. The start period is not restarted: it is
  counted from the container's `started_at_ms` in its observed record.
- **A refused check counts as neither a pass nor a failure.** A check the runtime cannot run says
  nothing about the service; counting it would turn a runtime fault into a rollback. The verdict
  stands and the record carries ZC-E0516 (the runtime's code and cause first) until a check runs.
- **Written on a change of the verdict or of the problem kind** (none, timed out, refused), not on
  each check: a passing service writes nothing, as every other observation. `health_failures`
  and `last_probe_exit` are what the checks said at the last such change.
- **A pass in the start period counts and does not end the period.** Failures in it are not
  counted; a pass is evidence of health whenever it comes. Ending the period at the first pass
  (Docker's rule) was not taken: one lucky pass would arm the failure count early.
- **The first check runs when the agent first sees the container running**, then every
  `interval_ms` from when the last one began (at once if it ran longer).
- **A check in flight is polled soon, then less often** (review fix, 2026-11-14):
  `probe_poll_ms_min` (100 ms, the fence's poll) after it began, then each time it has run twice
  as long, and at its timeout, and on the same doubling past it until the runtime reports it
  (`probe_scheduler.poll_at`). Polling only at the timeout saw a check that ended early late, and
  a check not reported by its timeout waited for the resync. An internal constant.
- **The cap of 8 stays provisional** until the supervisor confirms it (it is commented as such in
  `constants.zig`).

Where: docs/agent.md, "Health checks"; docs/keys.md, `/observed` version 3;
`src/probe_scheduler.zig`, `src/agent_health.zig`.
