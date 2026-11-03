# The replica controller may read `/assigned` and `/node-status/`

*Decided 2026-11-02.*

**The replica controller may read `/assigned` and `/node-status/`** (owner): to find a replica's observed record, and to replace a replica on a node `lost` past `lost_grace_ms` under a new id, comparing the replica, its assignment and the node status. New ids stay (owner reconsidered keeping the id and kept new ones: no two processes share an id while a cut-off node fences, and only the replica controller writes `/replicas/`). Nothing in C1 calls `move_replica`.

Where: `docs/authority.md` §2, §3
