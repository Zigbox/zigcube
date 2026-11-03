# C1 slice 3 part 1: src/scheduler.zig is the sole writer of /assigned, /allocations and (with the node controller's /node-status) the placement state; one placement, release or move per transaction, because the compare sets (6, 2, 8) leave no room to batch

*Decided 2026-10-31.*

C1 slice 3 part 1: `src/scheduler.zig` is the sole writer of `/assigned`, `/allocations` and (with the node controller's `/node-status`) the placement state; one placement, release or move per transaction, because the compare sets (6, 2, 8) leave no room to batch. The replica counter moves to `/replica-numbers/<service>` (replica controller; `Service` v2 reads a legacy `next_replica` only to seed it); the counter is never deleted (supervisor, 2026-10-31: one small key per service name ever applied), so a re-apply continues the numbering and replica ids are unique forever; the seed rule (a legacy `next_replica`, or one past the highest live replica) applies only when the key is absent. No C0 upgrade (a v1 replica's `node` is ignored). `src/node_controller.zig` is the minimum (marks `ready` for the tenure; lease expiry is slice 4). The scheduler and node controller keep a 30 s resync fallback besides their watches, matching the replica controller's (`resync_ms` there since C0): a missed wake-up is retried, a converged pass writes nothing.

Where: `docs/briefs/c1-3.md`, `docs/authority.md`
