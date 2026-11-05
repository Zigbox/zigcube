# 2026-11-05: a floor under the lease ttl (#78)

**Decision.** `fencing.inequality_problem` refuses a ttl under `fencing.ttl_floor_ms()`, derived
from constants: the agent renews `ttl / lease_renew_divisor` after the acknowledged keepalive and
fences `fence_margin_ms` before the ttl ends, so the slack after a renewal is `ttl - ttl / 3`. It
must cover the margin plus `lease_renew_jitter_ms` (`2 * agent_resync_ms`: a wake lands on a resync
boundary, and one retry follows a failed attempt). That is `ceil(3 * (3000 + 2000) / 2) = 7500` ms.
The server refuses a lower ttl at config time with the existing **ZC-E0121** (new cause: "under the
floor a renewal needs"); no new code, because the setting is the same one and the fix is the same
kind (choose a ttl between a floor and a ceiling). Its explanation now says a too-short lease fails
the other way: the agent fences before its renewal can arrive.

**Evidence.** Replaying the #78 family (seeds 254 and 343 with their replay lines, crash_heavy,
`--c1`): both fail with the busy loop at ttl 6000 and pass at 7000, 7500, 8000, 8500 and 9000.
The healed one-node case `sim_cluster 3 40 1` fences for ever at 4000 and stays quiet from 7500.
The floor is not the measured cliff (between 6000 and 7000) but the derived value above it, so a
change in `agent_resync_ms` or the divisor moves it with them.

**Simulator.** `sim_shape.lease_ttl_ms_min` is now the floor, so auto shapes draw only admitted
ttls. `sim_cluster` checks that a healed cluster stops fencing (`healed_stops_fencing`: no node
fences more than `fences_after_heal_max` = 2 times between the heal and the end). The teeth test
`zig build sim-c1-teeth-floor` runs seed 3 with the floor switched off (`c1_teeth_ttl_floor_off`)
and ttl 4000, and passes only if that check fires.

**Not decided here.** The `lease_renew_jitter_ms` factor is a judgement (two resync periods); the
measurements bound it only from above (7000 holds). A lower value would be 1.5 * (3000 + 1000) =
6000, which fails.
