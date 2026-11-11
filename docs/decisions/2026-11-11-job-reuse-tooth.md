# The `job_reuse` tooth is built (B2.1 slice 4)

*Decided 2026-11-11, by the B2.1 slice 4 implementer under docs/briefs/b2.1.md.*

This supersedes `2026-11-09-b2-ships-without-job-reuse.md`, which is left as written.

## What was built

- **The seam.** `Cluster.retention_jump` runs `job_retention.prune` twice (the first pass
  completes a `/job-observed/` sweep cycle, the second drops jobs old at its start) on a clock
  moved past the retention age, in one call that ticks no agent. In the reuse world, every third
  `job_create` operation does it and then makes up to four creates of deleted names at once
  (`reuse_job`), preferring a name whose node holds a stopped container that exited, so that the
  container of the earlier job still stands when the name is made again. The run id is
  `<name>-job`, so the new run meets that container.
- **J11.** A run whose status is `exited`, or `failed` by `oom` or `pid_limit`, is an ending only a
  real container has, so a node must have started the run in its own incarnation (the ledger is
  keyed by the run's `/job-runs` create revision in this world: `sim_jobs.run_hash`). `running`
  (reported ahead of the start) and `failed deadline` (a start record whose step aborted before
  `runtime.start`; 8 of 60 seeds of the world failed when I judged it) are not judged.
- **The tooth** (`sim-c1-teeth-job_reuse`) makes the simulated node's listing (`sim_node.zig`)
  report every job container's `zcube.created` as `maxInt(u64)`: the agent's stale-epoch rule is
  blinded, and a stale container is taken for the new run's. `agent_jobs.zig` is untouched. J11
  must fail.
- **The world** (`sim-c1-reuse`, `sim_c1_reuse_world_main.zig`) is the same world with the agent
  right; every check must hold. It runs in CI's `sim-worlds` job.
- Runs outside the reuse world are unchanged bit for bit (the new code is behind
  `c1_teeth.reuse_world`; the report line is printed there only).

## Measured (seeds 1 to 60, 300 operations, `--c1`)

- Reuse: 350 jumps, 986 jobs dropped, 404 reused creates, 367 of them met a container (91 %);
  every seed had at least one.
- Tooth: J11 fails on 49 of 60 seeds (82 %). The world with the agent right: 0 of 60 fail.
- The range is 1..60 and the canary cycle runs 60 seeds.

## Two things the world exposed

1. **A model gap in I4** (`writers.zig`). Retention's sweep of stray `/job-observed/` keys deletes
   in batches across nodes and jobs; `retention_only` rejected it. Retention had never run in the
   simulation. `observed_sweep_only` accepts a delete-only request on that prefix (with a test).
2. **J4's client and a clock jump.** The jump stands for an hour in zero time; the J4 client, which
   is never away that long, missed endings retention then deleted. `retention_jump` lets the client
   catch up first (`sim_jobs_watch.finish`). A real client away for more than the retention age
   loses endings by design; this is not a server finding.

## Handoff

- The fault sits in `sim_node.zig`'s listing, not in `agent_jobs.zig` (slice 6 works there).
- Earlier I placed the lie in `sim_runtime.zig`; the cluster's node uses `sim_node.zig`'s listing
  and never reaches it.
