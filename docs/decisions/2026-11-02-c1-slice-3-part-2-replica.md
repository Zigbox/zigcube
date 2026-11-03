# C1 slice 3 part 2: Replica is v2 (no node, no requests; v1 still reads)

*Decided 2026-11-02.*

C1 slice 3 part 2: `Replica` is v2 (no `node`, no `requests`; v1 still reads). The replica controller no longer places; `src/control_plane.zig` runs node controller, scheduler and replica controller in that order in the server, `sim_world`, `sim_c0` and `sim_cluster`, each controller on its own instance (`3i`, `3i+1` replica controller, `3i+2` scheduler: decision ids sort by time then instance, so a creation sorts before its placement within one millisecond). `check_i6` runs `Scheduler.find_mismatch` after each pass in tests and sims. Readers of a replica's node read `/assigned` (`Snapshot.node_of`). The agent endpoint serves the replica record (no `node` field) for replicas in `/assigned/<node>/` only; its watch and the agent's cover `/replicas` and `/assigned/`. The scheduler keeps its own `indexed_decision`; the replica controller's duplicate was dropped.

Where: `src/control_plane.zig`, `src/agent_api.zig`, `docs/keys.md`
