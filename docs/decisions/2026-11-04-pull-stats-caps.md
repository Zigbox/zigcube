# Pull statistics: a 1,000-record read cap and partial-run pruning

**Decision.** `GET /v1/stats/pull` reads at most `pulls_read_max` = 500 records (rows examined,
kept or skipped) and says `truncated: true` when it stopped there, never ZC-E0302. Retention keeps a
cursor (`continue_after`) across passes and prunes the part of each node's run it has read.

**Measured** (`src/pull_arena_test.zig`: 1,000 + 500 maximum records of 3,036 bytes, 11 peers
named in each list at maximum-length names, one request under a `BoundedArena` of exactly
`request_arena_bytes_max`, 16,777,216 bytes). `used_bytes` at the cap of 500: SQLite 4,644,368,
memory 4,789,304 (under 30% of the arena). At the earlier cap of 1,000: SQLite 7,307,524 (2.3x
headroom), memory 16,776,362 and a ZC-E0207 (before the page-only copy; with it, 7,590,964). The memory store, not the parse, was the cost: each
page copied every entry under the prefix, so a read of N records cost pages x N values; it now
copies the page it returns (`store_memory.zig`). The earlier "11.9 KB parse per record" figure
came from that and was wrong.

**What guards what.** `src/pull_arena_test.zig` guards the 2x arena bound (used bytes at most
half of the arena); it does not fail at the old cap of 1,000 (measured 7,590,964 bytes on memory,
under the 2x check). The cap itself is guarded by the comptime assert in `src/constants.zig`.
The memory store's `list` no longer lists every entry under the prefix for a current-state page:
it keeps only the `limit` + 1 entries it returns (a historical `at_revision` page still does).

**Derivation.** Per record: the value copy and the key copy the store makes (SQLite, Postgres),
and the parse, which is at most the value again: measured about 5.0 KB for 3,036 bytes. The
constant (`pull_read_arena_bytes`) takes the bound instead: key + 2 x 4 KiB + 1 KiB, about 9.7 KB,
roughly 1.9x the measurement. `constants.zig` asserts at compile time that `pulls_read_max` + 1
of those, the response buffer taken whole (`pulls_response_bytes`, about 2 MiB: an arena frees
nothing), the sort order and 64 KiB of slack come to at most half the arena (about 7.1 MiB of 8).
Rows that do not parse count toward the cap, so malformed rows cannot grow the read; a value over
`pull_record_bytes_max` or more than `pull_peers_max` peers is Malformed (counted in `skipped`).
Retention that restarted at the first page starved every node past the first 2,000 records.
Pruning a partial run is safe because a record's age does not depend on others, and a dropped
record has at least `pulls_per_node_max` newer ones in the whole set.

**Not done.** A streaming top-K read would give exact newest-first statistics without a cap; the
console and CLI show `truncated` instead. A retention failure is kept in the cursor and printed
once by `server_drive` (the core cannot log). A `pull.json.tmp` left by a crashed fetch child is
not removed: removing it could race a live child.
