# C1 slice 2b part E: sim_cluster.zig drives the real controllers and N real agents over SimNet with a seed-drawn swarm

*Decided 2026-10-31.*

C1 slice 2b part E: `sim_cluster.zig` drives the real controllers and N real agents over `SimNet` with a seed-drawn swarm. Replica counts are capped so the services fit the nodes' CPU (an unplaceable replica is not a bug); duplicates are counted per virtual second and never fail a run. Seed 217 of 1-400 fails: a deleted replica's stopped `Observed` record survives, the id is reused on the same node, and `Pass.replicas` (`src/agent.zig`) sees the stale record and never starts it. Left unfixed for the supervisor.

Where: `src/sim_cluster.zig`
