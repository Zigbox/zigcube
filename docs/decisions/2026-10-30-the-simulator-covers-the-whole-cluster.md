# The simulator covers the whole cluster, as C1 slice 2b before the scheduler (owner; the slot is the supervisor's call)

*Decided 2026-10-30.*

The simulator covers the whole cluster, as C1 slice 2b before the scheduler (owner; the slot is the supervisor's call). The agent's loop, endpoint client and persisted state (`AgentState`) move into the core; a `Network` seam with partitions and lost responses, a clock per node, agent crashes, the store's lost acknowledgement; `sim_cluster.zig` with swarm testing, a liveness mode and a shrinking seed runner. Duplicates are counted, not failed, until slice 6's fencing. Later, not in 2b: a seed fleet with a hub that files issues, a `Runtime` conformance suite against real Zigbox, a Postgres fault proxy, a nightly chaos lab.

Where: `docs/briefs/c1-2b.md`
