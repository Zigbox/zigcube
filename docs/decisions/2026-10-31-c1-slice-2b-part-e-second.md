# C1 slice 2b part E, second review: the sim also fails a placed replica of a good image that has no running container on its own node for 24 s (virtual time its agent is up, its link not cut, the store up, and its last step worked)

*Decided 2026-10-31.*

C1 slice 2b part E, second review: the sim also fails a placed replica of a good image that has no running container on its own node for 24 s (virtual time its agent is up, its link not cut, the store up, and its last step worked). Measured over seeds 1 to 300 at 100 operations: 20.1 s at most with the agent fix of caca12c, 25 s (seed 24), 30 s (155) and 48 s (296) without it, so the bound is 24 s; counting time while steps fail (a lossy link) reached 33 s on a healthy agent. Convergence also requires the container's image and the Observed generation to equal the replica's. The work floor is 5 successful agent steps per minute of uptime for each node up for half of the fault phase (slowest seen: 10). The invariant pass is skipped while the store revision and drop count are unchanged.

Where: `src/sim_cluster.zig`
