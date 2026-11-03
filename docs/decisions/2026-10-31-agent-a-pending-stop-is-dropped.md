# Agent: a pending stop is dropped when the replica is wanted again with its container (Pass.replicas, the branch where the container is this replica's)

*Decided 2026-10-31.*

Agent: a pending stop is dropped when the replica is wanted again with its container (`Pass.replicas`, the branch where the container is this replica's). A replica moved off a node and back before its container ended (one that ignores the polite stop) left the stop pending; after its deadline the next wake was always now (a busy loop: 1 078 steps in 20 s on one node of seed 744 at 100 operations) and the kill would have hit the wanted container. The regression test is in `src/sim_c0.zig`.

Where: `src/agent.zig`, `src/sim_c0.zig`
