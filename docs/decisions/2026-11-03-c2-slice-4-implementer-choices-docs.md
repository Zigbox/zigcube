# C2 slice 4 (implementer choices, docs/briefs/c2-4.md): sketch entries are 12 bytes (8-byte key, 4-byte size) so the estimate is weighted by bytes; the estimate compares the target's sample with the union of the held samples over the key range both cover exactly; the fetch plan hashes the bytes itself (receive takes bytes, not a verdict), so "never accepts an unverified chunk" is a property of the plan; ZC-W0601 is a warning with external blame, raised once per struck peer; the caller owns the plan's ChunkState slice and the peers' filter bytes; tidy lets fetch_plan.zig read the root file, as agent.zig does, for the sim-swarm-teeth fault.

*Decided 2026-11-03.*

C2 slice 4 (implementer choices, docs/briefs/c2-4.md): sketch entries are 12 bytes (8-byte key, 4-byte size) so the estimate is weighted by bytes; the estimate compares the target's sample with the union of the held samples over the key range both cover exactly; the fetch plan hashes the bytes itself (`receive` takes bytes, not a verdict), so "never accepts an unverified chunk" is a property of the plan; ZC-W0601 is a warning with external blame, raised once per struck peer; the caller owns the plan's `ChunkState` slice and the peers' filter bytes; `tidy` lets `fetch_plan.zig` read the root file, as `agent.zig` does, for the sim-swarm-teeth fault.

Where: docs/swarm.md
