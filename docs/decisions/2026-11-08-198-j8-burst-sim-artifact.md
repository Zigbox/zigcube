# #198: J8 failing in the burst world was a simulator artefact

## Verdict

Not an agent or job-controller bug. The simulator judged J8 from the wrong start time.

## Evidence

Reproduced on fbca677 (`sim_c1_world 2 300 --c1`, evict world, tooth off): `J8 ... (seed 2, at
36758 ms)`. Tracing the run it named (`jb-59`, deadline 3001 ms, grace 151 ms, one node):

- The step that started it began at true 29604 ms and charged 6359 ms of calls. The container was
  started 4689 ms into it (`Node.spent_ms`), at true-equivalent 34293 ms; its `claimed` start
  record, written just before, armed the deadline at 797612 on the node's clock, due 800613
  (true-equivalent 37292 ms). The agent's step at 36061 ms found it not yet due.
- J8 counted from `first_seen_ms` = 30504 ms, 3789 ms before the start, so it saw 6254 ms against a
  bound of 6172 ms (an 82 ms miss, with the run 1.4 s from its real deadline).
- Cause: `Node.started_true`, the ring of the true times of a node's latest job starts, held 8
  entries. The world's bursts of 12 creates start dozens of runs in one step; `jb-59`'s entry was
  overwritten, `started_true_of` returned null, and the fallback (`c.manual.ms` at the first tick
  that showed the container) is earlier than a start late in a long step.

The agent's enforcement behaved as designed: no deadline was passed on the agent's own clock.

## Fix and regression

- `started_true_max = 4 * jobs_per_node_max` (256) entries, `started_next` a `u16`.
- `zig build sim-c1-burst` (`src/sim_c1_burst_world_main.zig`, `c1_teeth.burst_world`, not a
  tooth): one node, creates 40 and ends 30, bursts of 12 short jobs (deadlines 3 s to 4 s), 300
  operations, seeds 1..2, about 25 s a seed. CI's sim job runs it. With the ring at 8, seed 2 fails
  J8; with 256 both seeds pass.

## For the RB-N8 teeth work (claude/b2-rbn8-teeth)

Its evict world's J8 failure was this artefact; with this fix its remaining questions (more than
512 starts on one node needing turnover, the reuse world's cost) are as that note records.
