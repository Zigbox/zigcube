# B2 slice 1, part 2: handoff (stopped at the turn ceiling)

Done in part 2: `zig-pkg` restored (AGENTS.md workaround); analysis of RA-SHOULD1 below. No gates run.

## Task 1: regression for the sim clock fidelity fixes (not done)
A `frozen_clock` tooth (node clock frozen inside a step, J8 counted from the step's first tick)
was tried and dropped: `--seeds 1..10 100 --c1 --expect-fail` finds no failing seed, and the
replay lines of #151 and #142 also pass with it. The old failures needed the old agent's per-call
floor (fix 3) as well. Next: a `sim-c1-regress` build step that runs the replay lines of #151,
#142, #143 and the slow_store seeds 31 and 102 (find their op counts) and must pass; show the
same lines failing on `ea4005a` (build there in a worktree with its own `ZIG_GLOBAL_CACHE_DIR`
and a copy of `zig-pkg`).

## Task 2: Rig test for one floor per step (not done)
Plan: in `agent_jobs_test.zig`, one run with a deadline about 300 ms after the step's start,
`keepalive_cost` 150 ms with `cap_ms = &world.call_cap_ms`; advance the manual clock to the lease
renewal, call `world.agent_step()` once, and assert `world.call_cap_ms == T + 1000` (T = clock
before the step). Old code gives `T + 1150` (floor taken after the heartbeat).

## Task 3: RA-SHOULD1 analysis (fix not made)
A cancel reaches the agent only as `entry.rec.stop` of the assignments read by `Pass.load`
(`agent.zig:905`) and acted on in `agent_jobs.pass` (`agent.zig` step, after `pass.replicas()`).
- A failing server call (load, heartbeat) ends the step first: the cancel is not seen. Bounded by
  the fence (J6's fence term).
- Not bounded: `pass.replicas()` and `agent_jobs.pass` run in sequence with `try`. A replica
  error that is not a transport error and repeats (a runtime `start`/`inspect` that returns an
  error, `agent.zig` `start`, `replace_stale`) fails the step after `load` succeeded and before
  the job pass: the heartbeat succeeds, so no fence, and the cancel is withheld for as long as the
  replica error lasts.
- Local fix, no bound, default or code changes: run `agent_jobs.pass` before `pass.replicas()`,
  keep its error, run the replica pass, and return the replica error (diag intact) else the job
  error. Needs a Rig test: a replica whose `start` errors plus a cancelled run; the run must stop.
  The same applies in the other direction (a job error holding replicas) and the fix covers it.

## Tasks 4 to 6: not started
Docs (docs/core.md clock fidelity and true start), all gates, REVIEW.md, PR with `full-ci`,
issue closing (#135 #137 #143 after the PR is open; #151 #142 with cause and commits).
Replay lines are in the issues.
