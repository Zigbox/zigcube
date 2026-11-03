# C1 slice 6: the server grants its own lease ttl and the agent adopts it (Config.lease_ttl_ms is gone from the agent; --lease-ttl-ms on the server, refused with ZC-E0121 when fence_margin < fence_stop + ttl*skew + kill_latency: at 10 s the margin is exactly 3000, so 20 s and 30 s are refused)

*Decided 2026-11-02.*

C1 slice 6: the server grants its own lease ttl and the agent adopts it (`Config.lease_ttl_ms` is gone from the agent; `--lease-ttl-ms` on the server, refused with `ZC-E0121` when `fence_margin < fence_stop + ttl*skew + kill_latency`: at 10 s the margin is exactly 3000, so 20 s and 30 s are refused). The tenure is the revision of the `/nodes/<node>` put; observed writes carry it as `tenure` and the server compares it (`ZC-E0510`, 503). The agent fences at `s + ttl − margin` on `CLOCK_BOOTTIME`, `s` and the lease are in `lease.json`, and a restart restores them before capping its first call. `Store.lease_grant`'s wrapper assertion is a range check now (the grant may differ from the request). The sim's invariant clock restarts while a node is down (a dead agent cannot fence). Found by the sim: seed 122 (`100 ops --heal-at=60`), a restored lease did not cap the first call.

Where: `src/fencing.zig`, `src/agent.zig`, `docs/briefs/c1-6.md`
