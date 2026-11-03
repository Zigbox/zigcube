# SimNet.tick(now_ms): parked (reordered) requests are delivered when the cluster reports the clock, not by the next call on the link.

*Decided 2026-10-31.*

`SimNet.tick(now_ms)`: parked (reordered) requests are delivered when the cluster reports the clock, not by the next call on the link.

Where: `src/sim_net.zig`, `docs/core.md`
