# C1 slice 7 review (owner): http_holds_max 24 -> 50 and http_connections_max 64 -> 96; store_postgres_watches_max stays 64 (50 + 2 < 64); Postgres needs max_connections >= 80 (AGENTS.md)

*Decided 2026-11-02.*

C1 slice 7 review (owner): `http_holds_max` 24 -> 50 and `http_connections_max` 64 -> 96; `store_postgres_watches_max` stays 64 (50 + 2 < 64); Postgres needs `max_connections` >= 80 (AGENTS.md). Sharing one store watch across holds (fan-out) is a later item. A refused watch (503 ZC-E0108) or any failed watch now backs off through the loop's `pausing` state instead of re-listing at once.

Where: `src/constants.zig`, `src/agent_loop.zig`
