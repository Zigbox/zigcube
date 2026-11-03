# Store rollback guard, agent side (C1 10b): every agent endpoint's answer carries chain (the store's status after the work, plus known_hash at the agent's known); the agent's RemoteStore refuses an answer from behind its remembered pair with ZC-E0215 before acting on it, and a reply without chain with ZC-E0504 (upgrade the server before the agents)

*Decided 2026-11-02.*

Store rollback guard, agent side (C1 10b): every agent endpoint's answer carries `chain` (the store's `status` after the work, plus `known_hash` at the agent's `known`); the agent's `RemoteStore` refuses an answer from behind its remembered pair with `ZC-E0215` before acting on it, and a reply without `chain` with `ZC-E0504` (upgrade the server before the agents). The pair persists to `<state dir>/remembered` (`put_atomic`, at most every `verified_save_ms`); no file is nothing remembered, a damaged one is `ZC-E0216`. `RemoteStore.hash_at` stays unsupported. The way out: `accept-rollback` on the server, then `rm <state dir>/remembered` and restart the agent.

Where: `docs/api.md`, `docs/agent.md`, `src/agent_client.zig`
