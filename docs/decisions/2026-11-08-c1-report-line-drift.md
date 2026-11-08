# The `--c1` report's jobs line drifted twice (2026-11-08)

*Decided 2026-11-08, by the slice (issue #193, from the review of #192).*

#192 made the cluster simulator judge wedged nodes in J6 and J8 for old-world seeds too (a node's
wedged time is now kept whenever jobs are on). That changed the `jobs: worst stop/past deadline`
line of the `--c1` report for some old-world seeds: the figures were measured with no wedged time
taken out before. Verdicts (pass or fail) and world hashes did not change, and no merged decision
file is edited for it.

`deadline_worst_ms`, the "past deadline" figure, still counted time the run's node spent wedged
after the deadline, which J8 excuses: a seed where J8 passed could report seconds past the
deadline that were only wedged time (seed 84 of `--seeds 1..100 auto --profile=auto --c1`: 12246
ms; 53: 506 ms; 96: 2958 ms). This change makes the figure net of that wedged time, measured the
same way J8 measures it (`sim_jobs.deadline_past_ms`), so the line changes a second time for the
seeds that had wedged time. Those three now report 0 ms; seeds with no excused wedged time
(21, 25, 66) are unchanged, because what remains there is J8's own allowance (the kill's latency
and the simulator's granularity).

Verdicts and world hashes are again unchanged. Anyone who compared `--c1` report lines across
#192, or kept a line as a baseline, should regenerate it; nothing in the repository compares the
line's text.

Where: `docs/core.md`, "sim-c1" (J8).
