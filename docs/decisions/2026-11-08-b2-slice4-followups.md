# B2 slice 4 follow-ups: slow seeds, RB-N8, #78 text

## Decisions

- **MemoryStore keeps its live table sorted by key.** Lookups and prefix ranges are binary
  searches, a historical `get` scans the log backwards from the revision, and compaction keeps the
  latest put of each key in one backward pass. Reports are bit-for-bit the old ones. The `--c1`
  seeds 12, 19, 27, 44 and 69 (`--seeds N..N auto --profile=auto --c1`) went from 79 to over 200 s
  down to 26 to 62 s, under the 150 s per-seed cap the fleet-profiles decision uses (the fleet
  itself has only a 3600 s batch timeout per 100 seeds).
- **RB-N8, the checker half.** `track_jobs` judges every live job container: J6 and J8 run on
  wedged nodes too (they subtract the node's wedged time), and only J1's clock waits for a node
  that is not wedged lately. `watch_max` is `16 * runtime_handles_max`, so no container lacks a
  slot (a comptime assert ties it to `nodes_max`).
- **#78 text.** The lease-ttl draw already starts at 8,000 ms on main (`sim_shape.zig`); only the
  AGENTS.md sentence and the `--lease-ttl-ms` refusal text were stale.

## Not done

- The two teeth (more than 512 runs on one node, job-name reuse) are not written. Each needs a
  world that makes more than 512 short jobs on one node (the runtime evicts stopped containers at
  `runtime_handles_max`) or a reused name past `job_finished_age_ms_min` (1 h of simulated time),
  and a fault in `agent_jobs.zig` (`gone`) that the checks must catch. Start from
  `c1_teeth_roots` in build.zig and `src/c1_teeth.zig`.
