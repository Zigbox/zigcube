# RB-N8 teeth: work in progress (neither tooth fires yet)

## State

Pushed as a work-in-progress commit. `zig build check` was **not** run; neither tooth passes
`sim-c1-teeth`, and `sim-c1-worlds` fails. AGENTS.md and docs/core.md teeth lists are not updated
(do that once both teeth fire). `c1_teeth_roots` has `job_evicted` and `job_reuse`: if left as
they are, `sim-c1-teeth` fails.

## What exists

- `c1_teeth.zig`: `job_evicted`, `job_reuse` (teeth) and `evict_world`, `reuse_world` (worlds,
  also switched by `c1_evict_world` / `c1_reuse_world`, declared by `src/sim_c1_*_world_main.zig`).
- `agent_jobs.zig`: `job_evicted` makes `gone` start a run again whose container is gone while
  its record is past `claiming`, the run still assigned and not stopped (J2). `job_reuse` makes
  `is_stale_epoch` return false (leftovers of an earlier job of the name taken for the new one).
- `sim_cluster.zig`: evict world = one node (`plan`), `w_job_create` 40, `w_job_end` 30, bursts
  of 12 creates, deadlines 3 s to 4 s; reuse world = names reused half the time, an hour and two
  minutes of simulated time after one in eight `advance` operations. `jobs_converged` lists up to
  `job_admitted_window_max` runs (was `jobs_max` = 512, which the evict world exceeds: "the job
  job_runs cannot be read").
- `build.zig`: `ops` per teeth entry (evicted 300, reuse 300), `sim-c1-worlds` (seeds 1..5).

## Findings

- The evict world, **agent right** (`sim_c1_world 2 300 --c1`), fails J8 at 36 s ("a run kept
  executing past its deadline"): the burst load is the cause, not the tooth. Deadlines of 1 s to
  3 s fail J8 even more (seed 1 at 60 s). Likely a simulator artefact like the step overrun of
  #171; find out before relying on the world. Fewer creates per burst may fix it.
- With 150 ops and bursts of 12, seed 1 made 506 creates but only 212 starts: runs wait for the
  64 per node, and `submit_by_ms` (5 s to 25 s) expires. More than 512 *starts* on one node needs
  turnover (ends, short deadlines) without the J8 trouble. 300 ops take about 25 s a seed.
- Unknown: whether, at 513+ starts, the assigned record of an evicted container exists (an ended
  run may be released first, so `gone` with `subject.assigned` never happens). If it does not,
  fault the `lost` path instead, e.g. report `lost` over a stopped observation.
- The reuse world was not seen to finish (8 seeds at 300 ops over 500 s, a one-hour `advance` is
  36,000 ticks). Coarser ticks while idle, or a smaller jump, may be needed. Whether a leftover
  stopped container/observation exists after retention is unverified; J8 is a guess at the symptom.
- Each full `zig build` of the 19 teeth runners took 5 to 13 minutes.
