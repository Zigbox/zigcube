# C1 slice 2b part E review fixes: the sim checks per container and per virtual second (a container no replica assigns to its node may live 120 s of time its node is reachable and the store is up); the end check goes replica by replica; faults are rationed (cuts at most half the nodes, none in a one-node world; short outages; per-call loss at most about 1 %) and a floor of fault-phase agent work fails the run; the world hash covers agent files, loop state and parked requests.

*Decided 2026-10-31.*

C1 slice 2b part E review fixes: the sim checks per container and per virtual second (a container no replica assigns to its node may live 120 s of time its node is reachable and the store is up); the end check goes replica by replica; faults are rationed (cuts at most half the nodes, none in a one-node world; short outages; per-call loss at most about 1 %) and a floor of fault-phase agent work fails the run; the world hash covers agent files, loop state and parked requests.

Where: `src/sim_cluster.zig`
