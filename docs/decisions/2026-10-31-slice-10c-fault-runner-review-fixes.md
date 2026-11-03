# Slice 10c, fault runner review fixes: the runner proves it can fail (--mutate drop_ack|stale_read|reuse_revision, src/store_mutant.zig, asserted in zig build test on SQLite; a duplicated revision is revision_reused, which the checker meets before revision_order)

*Decided 2026-10-31.*

Slice 10c, fault runner review fixes: the runner proves it can fail (`--mutate drop_ack|stale_read|reuse_revision`, `src/store_mutant.zig`, asserted in `zig build test` on SQLite; a duplicated revision is `revision_reused`, which the checker meets before `revision_order`). The proxy's `cut_on_commit_reply` makes the lost acknowledgement happen on demand, and a faulted run that finds no unknown write in the log fails. Contention comes from hot keys per phase (4 keys, 16 calls per client per phase) rather than a raised bound: the checker's `key_calls_max` of 64 stays, because its search has no memoization and a bigger bitset would only invite `search_exhausted`; the runner caps a key at 56 calls. Only a ZC-E0213 raised during COMMIT is `unknown` (`pq.dropped_during_commit`); an earlier drop is `fail`. After healing, the runner waits for the store's backends to go idle before it reads the final revision.

Where: `src/store_faults.zig`, `src/store_mutant.zig`, `src/testing/fault_proxy.zig`, `src/pq.zig`
