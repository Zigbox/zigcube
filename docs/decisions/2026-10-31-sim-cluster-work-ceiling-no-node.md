# sim-cluster work ceiling: no node's agent takes more than 200 steps (failed ones too) per minute of agent uptime over the whole run, so a busy loop fails the run

*Decided 2026-10-31.*

sim-cluster work ceiling: no node's agent takes more than 200 steps (failed ones too) per minute of agent uptime over the whole run, so a busy loop fails the run. Measured over seeds 1 to 300 at 100 operations: 97 at most (seed 275; 62 on seed 150); seeds 150, 505, 375 and 329 exceed it with the stale-stop bug of 1aa2248 (seed 150 took 20 385 steps against 1 942).

Where: `src/sim_cluster.zig`
