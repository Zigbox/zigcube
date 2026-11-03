# sim-cluster work floor is cluster-wide: the nodes together must take 5 successful agent steps per minute of uptime while the faults are on, and the rate is checked only when their uptime in the fault phase totals 120 s

*Decided 2026-10-31.*

sim-cluster work floor is cluster-wide: the nodes together must take 5 successful agent steps per minute of uptime while the faults are on, and the rate is checked only when their uptime in the fault phase totals 120 s. The per-node floor (5 per minute for each node up for half the fault phase) failed seeds 842 and 465 (and about 0.3 % of seeds at 100 operations) without any bug: a node whose calls are lost or delayed spends 10 s on each failed step (5 failures in 67 s on seed 465's node 3, from a reordered request, a dropped request, two lost replies and a cut link), so one node's successes per minute is a few calls' luck, and a 1-operation shrink had a fault phase of a few seconds. Starvation of a node is caught by the 24 s placed-replica bound and the busy loop by the ceiling; the slowest node is still printed. Measured, seeds 1 to 1000 at 100 operations (812 of them above the 120 s uptime minimum): at least 15 per minute (3 times the floor); seeds 1 to 300 at 40 operations (97 above it): at least 19.

Where: `src/sim_cluster.zig`
