# C1 10b agent side, review fixes (replaces the matching parts of the row below)

*Decided 2026-11-02.*

C1 10b agent side, review fixes (replaces the matching parts of the row below). `chain` gains `verified` (additive): `false` when the server keeps no pair for its store across restarts (a memory store); an agent then neither refuses nor keeps a pair and says so once. Writes (registration, report) carry the pair of their own transaction; `known == revision` uses that hash. `<state dir>/remembered` is v2 and names the `--server` address it was saved for: a v1 file is an unknown address and its pair is kept; a pair for another address is not compared (one line, start fresh); `v` of 0 or not a number is damaged, only a higher one is newer. A store recreated at the same address is refused like a rollback (same `rm`). The pair is saved once more on a clean stop. Write gating is the server's `VerifiedStore` alone; the agent check guards what the agent acts on. **Gap for the owner (cut from 10b):** recovery after `accept-rollback` is per node (`rm` and restart on each agent); an accepted rollback could travel in `chain` as `{from, to}`, and an agent whose pair equals `from` would adopt `to`.

Where: `docs/agent.md`, `docs/api.md`, `docs/store-design.md`, `docs/briefs/c1-10b-agent.md`
