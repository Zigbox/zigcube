# C1 slice 6, demo-c0 step 5 (owner: "6: a"): the store refuses writes for at least 9 s, so the agent fences; the demo asserts every replica command dead within ttl of the moment the store stopped (at or after s + ttl, without waiting for the old lease to expire), ZC-W0501 printed, nothing running until the outage ends, then a higher tenure, new pids, no duplicates, and exactly mark_ready plus the replacement of the fenced replicas

*Decided 2026-11-02.*

C1 slice 6, demo-c0 step 5 (owner: "6: a"): the store refuses writes for at least 9 s, so the agent fences; the demo asserts every replica command dead within `ttl` of the moment the store stopped (at or after `s + ttl`, without waiting for the old lease to expire), `ZC-W0501` printed, nothing running until the outage ends, then a higher tenure, new pids, no duplicates, and exactly `mark_ready` plus the replacement of the fenced replicas. The agent prints `ZC-W0501` when a pass ends a fence even if the rest of that pass (registering again) fails; before, the warning was lost when the store still refused writes.

Where: `src/demo_c0_outage.zig`, `src/agent_run.zig`, `docs/demos/c0.md`
