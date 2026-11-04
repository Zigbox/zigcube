# Pull statistics: a 1,000-record read cap and partial-run pruning

**Decision.** `GET /v1/stats/pull` reads at most `pulls_read_max` = 1,000 records and says
`truncated: true` when it stopped there. Retention keeps a cursor (`continue_after`) across
passes and prunes the part of each node's run it has read.

**Why.** A worst-case record is about 9.7 KB in the arena (key, value and its parse), and the
request arena is 16 MiB; the earlier 6,400 could not fit, which `constants.zig` now asserts at
compile time. Retention that restarted at the first page starved every node past the first
2,000 records. Pruning a partial run is safe because a record's age does not depend on others,
and a dropped record has at least `pulls_per_node_max` newer ones in the whole set.

**Not done.** A streaming top-K read would give exact newest-first statistics without a cap; the
console and CLI show `truncated` instead. A retention failure is kept in the cursor and printed
once by `server_drive` (the core cannot log). A `pull.json.tmp` left by a crashed fetch child is
not removed: removing it could race a live child.
