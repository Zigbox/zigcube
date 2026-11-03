# A stopped Observed record left by an earlier replica with the same id never stands in for a new one: a service deleted and applied again restarts next_replica at 1 (the counter lives in the service record), so ids are unique per incarnation only until the counter gets its own key (slice 3, owner's decision above); until then the agent treats a record of another generation, or older than the replica key's create_revision, as a leftover and starts the replica

*Decided 2026-10-31.*

A stopped `Observed` record left by an earlier replica with the same id never stands in for a new one: a service deleted and applied again restarts `next_replica` at 1 (the counter lives in the service record), so ids are unique per incarnation only until the counter gets its own key (slice 3, owner's decision above); until then the agent treats a record of another generation, or older than the replica key's `create_revision`, as a leftover and starts the replica. Found by `sim-cluster` seed 32 (the part E note said 217; 217 passes).

Where: `src/agent.zig`, `src/sim_c0.zig`
