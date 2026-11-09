# RB-N8 teeth: `job_evicted` is built, `job_reuse` is not: the owner must accept that (issue #195)

Replaces `2026-11-08-b2-rbn8-teeth-not-built.md` (a merged decision is not edited).

## `job_evicted`: built, as a controller fault

- The agent-side fault the brief imagined cannot be reached: an ended run is released and its
  record removed before the runtime evicts its stopped container (`2026-11-08` note, unchanged).
- The tooth is the controller side of the same bound: with `c1_teeth_job_evicted`, each sweep
  of `job_controller.zig` judges only the first `jobs_max` (512) jobs of the admission window and
  starts over, so an unplaceable job past the 512th is never ended. Test-only; production code
  is unchanged.
- J8's second clause (`unclaimed_ended`) read only the first 512 runs and skipped silently. It
  now lists `job_admitted_window_max` runs, and a refused list fails with "J8: the runs of the
  second clause cannot be read". It still skips when the start ledger is full (`ledger_max`
  4096 starts).
- Hits over seeds 1..40 at 300 operations (burst world, `--strong`, one node): seeds 9 and 32
  fail with "J8: a run that no node started was still open long after its start_by_ms". The tooth
  runs seeds 1..13 (first hit 9) and the canary range is 13.
- Seeds 14, 17 and 19 fail J8 ("a run kept executing past its deadline, its grace and the kill")
  in this world with the fault off. 14 and 17 fail on clean `main` (3ff3dd6) in the burst world
  too (`sim_c1_burst --seeds 14..14 300 --c1`): filed as #202. 19 passes on `main`'s burst world
  and is presumed the same bug until #202's fix says otherwise. Both tooth ranges end before 14.
  `sim-c1-worlds` runs seeds 1 to 5 only for that reason.

## `job_reuse`: not built. The owner must accept its absence.

- The world made no reuse at all: seeds 1, 2 and 3 at 300 operations (a one-hour jump taken in 3 s
  steps on 1 in 32 advances, half the creates naming an earlier job) accepted **0** reused
  creates (`reuse made=0 met a container=0`, each seed). So nothing was measured about whether
  leftovers survive retention or whether `is_stale_epoch` is reached.
- With the fault on, seeds 1..6 passed (0 of 6 failed, 4m27s): the tooth does not fire in this
  world. A one-hour jump in 60 s steps made service checks fail (steps far above the lease ttl),
  and in 3 s steps costs about 45 s per seed.
- This is not a proof that the class cannot occur. The brief's slice 4 names the tooth; what
  would build it is a store-side retention jump that does not tick every agent (a different seam
  in `Cluster`), then a measured hit count. The unit tests of `agent_jobs.zig` still cover the
  stale-epoch rule directly.
- The reuse world, its root files and the fault were removed again from the branch.
